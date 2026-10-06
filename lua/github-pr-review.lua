-- ==========================================
-- GitHub PR レビュー画面
-- ==========================================
-- PR パネル（:GR）の行で R を押すと、PR の差分を diffview で開き、
-- 同じタブの右端にレビューの手引きを並べる。
--
--   diffview（左〜中央）  base と PR を左右に並べた差分。既存のレビューコメントは行末に出る
--   手引き（右端）        観点チェックリスト（ルールで自動振り分け）と AI レビュー
--
-- 開いた時点で PR の取り寄せ・既存コメント・AIレビューを裏で進めるので、
-- 追加のキー操作なしで全部そろう（AIレビューだけは数十秒かかる）。
--
-- 差分の中:    c 行にコメント / C PR全体にコメント / q 閉じる（ファイル移動は diffview の <Tab> / <S-Tab>）
-- 手引きの中:  Enter ファイルへ移動 / x チェック切替 / q 閉じる
--
-- PR の中身は `git fetch` で refs/remotes/origin/pr/<番号> に取り寄せる。
-- チェックアウトはしないので、作業中のブランチや未コミットの変更には触れない。
--
-- 外部への送信について:
--   * AIレビュー: PR のタイトル・本文・差分を `claude -p` に渡す
--                 （ツールは読み取り専用の Read/Grep/Glob だけ。テストの実行方法を調べるため）
--   * コメント:   入力して <C-s> を押したときだけ GitHub に投稿する

local M = {}

-- 右端（手引き）の幅
local SIDE_WIDTH = 56
-- AI に渡す差分の上限（文字数）。超えた分は切り捨てて、その旨を伝える
local AI_DIFF_LIMIT = 150000
-- AI レビューの打ち切り時間（ミリ秒）
local AI_TIMEOUT_MS = 5 * 60 * 1000
-- 行末に出す既存コメントの最大文字数（1件あたり）
local COMMENT_MAX_CHARS = 80

-- ------------------------------------------
-- レビューの観点（ルールでの自動振り分け）
-- ------------------------------------------
-- paths: ファイルパスに含まれていたら該当（小文字で比較。Lua パターン）
-- code:  追加・削除された行に含まれていたら該当（小文字で比較。Lua パターン）
-- 足りないパターンはここに足せばよい。
local VIEWPOINTS = {
  {
    key = "data",
    label = "データ変更・削除",
    check = "WHERE条件・影響範囲・トランザクション・ロールバックできるか",
    paths = { "migration", "seeder", "schema", "%.sql$" },
    code = {
      "delete%s+from", "update%s+[%w_`]+%s+set", "truncate", "drop%s+", "alter%s+table",
      "%->delete%(", "%->update%(", "forcedelete", "destroy%(", "unlink%(", "rm%s+%-rf",
    },
  },
  {
    key = "auth",
    label = "権限・認証・お金・個人情報",
    check = "誰が何をできるか・チェック漏れの経路・金額計算・個人情報の露出",
    paths = { "auth", "login", "password", "permission", "polic", "role", "payment", "billing", "invoice", "price" },
    code = {
      "password", "token", "authorize", "permission", "gate::", "%->can%(", "%f[%w]role%f[%W]",
      "price", "amount", "billing", "invoice", "email", "birth", "address", "%f[%w]tel%f[%W]",
    },
  },
  {
    key = "domain",
    label = "ビジネスルール",
    check = "仕様・要件と一致しているか・境界値（0・上限・月末・うるう年）",
    paths = { "service", "usecase", "domain", "models?/", "entit", "calculat", "rule" },
    code = { "status", "%f[%w]state%f[%W]", "carbon", "%f[%w]date%f[%W]", "month", "limit" },
  },
  {
    key = "flow",
    label = "入口・全体の流れ",
    check = "どこから入りどこを通るか・既存の呼び出し元への影響",
    paths = { "route", "controller", "kernel", "provider", "middleware", "bootstrap", "app%.[jt]sx?$", "main%.", "index%.[jt]sx?$" },
    code = { "route::", "router", "middleware", "register%(", "export%s+default" },
  },
  {
    key = "external",
    label = "外部との境界",
    check = "失敗時（タイムアウト・リトライ・二重実行）にどうなるか",
    paths = { "jobs?/", "queue", "console", "commands?/", "batch", "cron", "schedule", "%.env", "config/", "client" },
    code = { "http::", "curl", "fetch%(", "axios", "guzzle", "dispatch%(", "env%(", "process%.env", "retry", "timeout" },
  },
}

-- テストの変更とみなすパス
local TEST_PATHS = { "test", "spec", "__tests__" }
-- この行数（追加+削除）を超えたら「大きいPR」と注意する
local LARGE_PR_LINES = 400

local ns = vim.api.nvim_create_namespace("github_pr_review")

local function notify(msg, level)
  vim.notify("[PR Review] " .. msg, level or vim.log.levels.INFO)
end

-- JSON の null を nil にしてデコードする（vim.NIL を気にしなくてよいように）
local function decode(s)
  local ok, v = pcall(vim.json.decode, s or "", { luanil = { object = true, array = true } })
  if ok then
    return v
  end
  return nil
end

local function any_match(s, patterns)
  for _, p in ipairs(patterns) do
    if s:find(p) then
      return true
    end
  end
  return false
end

-- ==========================================
-- 差分の解析
-- ==========================================

-- `gh pr diff` の unified diff をファイル単位・hunk 単位に分ける
--   files = { { path, status, binary, add, del, hunks = {
--     { header, lines = { { kind = "add"|"del"|"ctx", text, old, new } } } } } }
local function parse_diff(text)
  local files = {}
  local cur, old_ln, new_ln

  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^diff %-%-git ") then
      local a, b = line:match("^diff %-%-git a/(.-) b/(.*)$")
      cur = { path = b or a or line, status = "modified", binary = false, add = 0, del = 0, hunks = {} }
      table.insert(files, cur)
    elseif cur then
      if line:match("^@@") then
        local o, n = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
        old_ln, new_ln = tonumber(o) or 0, tonumber(n) or 0
        table.insert(cur.hunks, { header = line, lines = {} })
      elseif #cur.hunks > 0 then
        -- hunk の中身。"--- " や "+++ " で始まる行もここでは中身として扱う
        local h = cur.hunks[#cur.hunks]
        local c = line:sub(1, 1)
        if c == "+" then
          table.insert(h.lines, { kind = "add", text = line:sub(2), new = new_ln })
          new_ln = new_ln + 1
          cur.add = cur.add + 1
        elseif c == "-" then
          table.insert(h.lines, { kind = "del", text = line:sub(2), old = old_ln })
          old_ln = old_ln + 1
          cur.del = cur.del + 1
        elseif c == " " then
          table.insert(h.lines, { kind = "ctx", text = line:sub(2), old = old_ln, new = new_ln })
          old_ln = old_ln + 1
          new_ln = new_ln + 1
        end
        -- "\ No newline at end of file" と空行は読み飛ばす
      else
        -- 最初の @@ より前のメタ情報
        local p = line:match("^%+%+%+ b/(.*)$")
        if p then
          cur.path = p
        elseif line:match("^new file") then
          cur.status = "added"
        elseif line:match("^deleted file") then
          cur.status = "deleted"
        elseif line:match("^rename from") then
          cur.status = "renamed"
        elseif line:match("^Binary files") then
          cur.binary = true
        end
      end
    end
  end

  return files
end

-- ファイルごとに該当する観点を調べる
--   返り値: hits[viewpoint.key] = { path, ... }, file.tags = { label, ... }
-- テストファイルは観点の振り分けから外す（本体のコードを見れば十分なため）
local function classify(files)
  local hits = {}
  for _, vp in ipairs(VIEWPOINTS) do
    hits[vp.key] = {}
  end

  for _, f in ipairs(files) do
    f.tags = {}
    local path = f.path:lower()
    for _, vp in ipairs(any_match(path, TEST_PATHS) and {} or VIEWPOINTS) do
      local matched = any_match(path, vp.paths)
      if not matched then
        for _, h in ipairs(f.hunks) do
          for _, l in ipairs(h.lines) do
            if l.kind ~= "ctx" and any_match(l.text:lower(), vp.code) then
              matched = true
              break
            end
          end
          if matched then
            break
          end
        end
      end
      if matched then
        table.insert(hits[vp.key], f.path)
        table.insert(f.tags, vp.label)
      end
    end
  end

  return hits
end

-- ==========================================
-- 状態
-- ==========================================
-- 1つのレビュー画面につき1つの state を作り、キーマップや autocmd のクロージャで持ち回る。
--   st = {
--     root, number, pr (gh pr view の結果), diff_text, files, hits, comments,
--     ai = { status = "running"|"done"|"error", text },
--     checks = { [viewpoint.key] = true },
--     tab, side_buf, side_win,
--     bufs = { [diffview のバッファ] = { path, side = "LEFT"|"RIGHT" } },
--     side_map = { [行番号] = { path = … } | { viewpoint = key } },
--     errors = { … },
--   }

-- AIレビューの結果は PR番号 + head の commit で覚えておき、開き直しでは再生成しない
local ai_cache = {}

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- ==========================================
-- 既存コメントの表示（diffview のバッファの行末）
-- ==========================================
-- diffview は左右の行をそろえて表示するため、行を増やす virt_lines ではなく
-- 行末の virt_text で出す（左右のずれを起こさない）。

local function decorate_buf(st, buf)
  local info = st.bufs[buf]
  if not info or not is_valid_buf(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)

  -- 同じ行の複数コメントは1つにまとめる
  local by_line = {}
  for _, c in ipairs(st.comments or {}) do
    -- line が無いのは、その後の push で位置がずれた古いコメント（outdated）
    if c.line and c.path == info.path and (c.side or "RIGHT") == info.side then
      by_line[c.line] = by_line[c.line] or {}
      table.insert(by_line[c.line], c)
    end
  end

  for line, list in pairs(by_line) do
    if line <= line_count then
      local first = list[1]
      local body = vim.trim(first.body or ""):gsub("%s*\n%s*", " ")
      if vim.fn.strchars(body) > COMMENT_MAX_CHARS then
        body = vim.fn.strcharpart(body, 0, COMMENT_MAX_CHARS) .. "…"
      end
      local text = string.format("  💬 @%s: %s", (first.user or {}).login or "?", body)
      if #list > 1 then
        text = text .. string.format("  (+%d件)", #list - 1)
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0, {
        virt_text = { { text, "DiagnosticInfo" } },
        virt_text_pos = "eol",
        sign_text = "💬",
        sign_hl_group = "DiagnosticInfo",
      })
    end
  end
end

local function decorate_all(st)
  for buf in pairs(st.bufs) do
    decorate_buf(st, buf)
  end
end

-- ==========================================
-- 描画: 右の手引き（観点チェックリスト + AIレビュー）
-- ==========================================

local function render_side(st)
  if not is_valid_buf(st.side_buf) then
    return
  end

  local lines = {}
  -- { 行番号(0始まり), ハイライトグループ }
  local hls = {}
  st.side_map = {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(hls, { #lines - 1, hl })
    end
  end

  -- --- PR の概要 ---
  local pr = st.pr
  if pr then
    add(string.format(" #%d %s", pr.number, pr.title or ""), "Title")
    add(string.format(" @%s   %s ← %s", (pr.author or {}).login or "?", pr.baseRefName or "?", pr.headRefName or "?"), "Comment")
    add(string.format(" +%d −%d / %dファイル", pr.additions or 0, pr.deletions or 0, pr.changedFiles or 0), "Comment")
  else
    add(string.format(" #%d 取得中でございます…", st.number), "Title")
  end
  if st.errors.meta then
    add(" PR情報を取得できませんでした: " .. st.errors.meta, "DiagnosticError")
  end
  add("")

  -- --- 観点チェックリスト ---
  add(" ── 観点チェックリスト ──  x で済みにする", "Title")
  if st.hits then
    for _, vp in ipairs(VIEWPOINTS) do
      local files = st.hits[vp.key]
      if #files > 0 then
        local done = st.checks[vp.key]
        add(string.format(" %s %s (%d)", done and "[x]" or "[ ]", vp.label, #files), done and "Comment" or "DiagnosticWarn")
        st.side_map[#lines] = { viewpoint = vp.key }
        add("     確認: " .. vp.check, "Comment")
        st.side_map[#lines] = { viewpoint = vp.key }
        for _, path in ipairs(files) do
          add("     ・" .. path)
          st.side_map[#lines] = { path = path }
        end
      end
    end

    -- --- 注意 ---
    local has_test, total = false, 0
    for _, f in ipairs(st.files) do
      total = total + f.add + f.del
      if any_match(f.path:lower(), TEST_PATHS) then
        has_test = true
      end
    end
    if #st.files > 0 and not has_test then
      add(" ⚠ テストファイルの変更がありません", "DiagnosticWarn")
    end
    if total > LARGE_PR_LINES then
      add(string.format(" ⚠ 変更が %d 行と大きいです。分けられないか検討を", total), "DiagnosticWarn")
    end
  else
    add("   差分の取得待ちでございます…", "Comment")
  end
  add("")

  -- --- 変更ファイル ---
  if st.files and #st.files > 0 then
    add(" ── 変更ファイル ──  Enter で差分へ", "Title")
    for _, f in ipairs(st.files) do
      add(string.format("   %s  +%d −%d", f.path, f.add, f.del))
      st.side_map[#lines] = { path = f.path }
    end
    add("")
  end

  -- --- AIレビュー ---
  add(" ── AIレビュー（テスト手順つき）──", "Title")
  if st.ai.status == "running" then
    add("   AI がレビュー中でございます…（数十秒かかります）", "Comment")
  elseif st.ai.status == "error" then
    add("   生成できませんでした: " .. (st.ai.text or ""), "DiagnosticError")
  elseif st.ai.status == "done" then
    for _, l in ipairs(vim.split(st.ai.text or "", "\n")) do
      add(" " .. l, l:match("^#") and "Title" or nil)
    end
  else
    add("   差分の取得待ちでございます…", "Comment")
  end

  set_lines(st.side_buf, lines)
  vim.api.nvim_buf_clear_namespace(st.side_buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, st.side_buf, ns, h[1], 0, { line_hl_group = h[2] })
  end
end

-- ==========================================
-- AIレビュー（claude -p）
-- ==========================================

local function ai_prompt(st)
  local diff = st.diff_text or ""
  local truncated = ""
  if #diff > AI_DIFF_LIMIT then
    diff = diff:sub(1, AI_DIFF_LIMIT)
    truncated = "\n（差分が長いため途中で切っています）\n"
  end
  local pr = st.pr or {}
  return table.concat({
    "あなたはシニアエンジニアのコードレビュアーです。以下の Pull Request をレビューしてください。",
    "日本語・Markdown で、前置きや口調の演出は不要です。レビュー本文だけを出力してください。",
    "リポジトリのファイルは Read / Grep / Glob で読めますが、作業ツリーは PR のブランチではない可能性があります。",
    "コードの内容は下の差分を正とし、ファイルはテストの実行方法など設定の確認にだけ使ってください。",
    "",
    "出力形式:",
    "## 概要",
    "（何をするPRか 2〜3行）",
    "## 動作確認の手順（画面）",
    "（レビュアーがブラウザで確かめる手順を番号付きで。開く画面のURL・事前に用意するデータ・操作・期待する表示を具体的に。",
    "  正常系に加えて、変更内容に関わる異常系・境界値も。画面に影響しないPRなら「画面での確認は不要」とその理由だけ）",
    "## 動作確認のコマンド",
    "（変更に関係するテスト・静的解析を実行するコマンドを ```sh のコードブロックで。変更・追加されたテストファイルはファイル単位で実行するコマンドにする。",
    "  コマンドは推測せず、package.json / composer.json / Makefile などを Read・Grep で確認して、このリポジトリで実際に使える形にする）",
    "## 重点的に見るべき箇所",
    "（`ファイルパス:行番号` と理由。最大7件。データ変更・削除 / 権限・認証・お金・個人情報 / ビジネスルール / 入口と流れ / 外部との境界 の観点を優先）",
    "## バグ・懸念の可能性",
    "（根拠のあるものだけ。なければ「特になし」）",
    "## 作成者に確認したいこと",
    "",
    "---",
    "タイトル: " .. (pr.title or ""),
    "本文:",
    pr.body or "（なし）",
    "",
    "差分:",
    diff,
    truncated,
  }, "\n")
end

local function start_ai(st)
  local key = st.number .. "@" .. ((st.pr or {}).headRefOid or "")
  if ai_cache[key] then
    st.ai = { status = "done", text = ai_cache[key] }
    render_side(st)
    return
  end

  if vim.fn.executable("claude") == 0 then
    st.ai = { status = "error", text = "claude コマンドが見つかりません" }
    render_side(st)
    return
  end

  st.ai = { status = "running" }
  render_side(st)

  -- テストの実行方法を調べられるよう、読み取り専用のツール（Read/Grep/Glob）だけ使わせる。
  -- コマンドの実行や書き込みはさせない。MCP サーバーも使わない（起動が遅くなり、余計な出力も混ざるため）
  vim.system(
    { "claude", "-p", "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--no-session-persistence" },
    { cwd = st.root, text = true, stdin = ai_prompt(st), timeout = AI_TIMEOUT_MS },
    function(obj)
      vim.schedule(function()
        if obj.code == 0 and vim.trim(obj.stdout or "") ~= "" then
          local text = vim.trim(obj.stdout)
          ai_cache[key] = text
          st.ai = { status = "done", text = text }
        else
          local err = vim.trim(obj.stderr or "")
          st.ai = { status = "error", text = err ~= "" and err or ("exit " .. tostring(obj.code)) }
        end
        render_side(st)
      end)
    end
  )
end

-- ==========================================
-- 取得
-- ==========================================
-- 1. gh pr view で base ブランチなどを知る
-- 2. そのあと並行して:
--      git fetch（diffview で開くため） / gh pr diff（観点とAI用） / 既存コメント
-- 3. git fetch が終わったら diffview を開く。PR情報と差分がそろったら AI を始める

local function run(st, cmd, opts, on_done)
  opts = vim.tbl_extend("force", { cwd = st.root, text = true }, opts or {})
  vim.system(cmd, opts, function(obj)
    vim.schedule(function()
      local err = nil
      if obj.code ~= 0 then
        err = vim.trim(obj.stderr or "")
        if err == "" then
          err = "exit " .. tostring(obj.code)
        end
      end
      on_done(obj.stdout or "", err)
    end)
  end)
end

local open_diffview

local function fetch_all(st)
  run(st, {
    "gh", "pr", "view", tostring(st.number), "--json",
    "number,title,body,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,url",
  }, nil, function(out, err)
    if err then
      st.errors.meta = err
      st.ai = { status = "error", text = "PR情報が取れなかったため実行しませんでした" }
      notify("PR情報を取得できませんでした: " .. err, vim.log.levels.ERROR)
      render_side(st)
      return
    end
    st.pr = decode(out)
    render_side(st)

    local pending = 2
    local function maybe_start_ai()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if st.diff_text then
        start_ai(st)
      else
        st.ai = { status = "error", text = "差分が取れなかったため実行しませんでした" }
        render_side(st)
      end
    end

    -- base と PR の head を origin の下に取り寄せる（作業ツリーには触れない）
    local base = st.pr.baseRefName
    run(st, {
      "git", "fetch", "--no-tags", "origin",
      "+refs/heads/" .. base .. ":refs/remotes/origin/" .. base,
      "+refs/pull/" .. st.number .. "/head:refs/remotes/origin/pr/" .. st.number,
    }, nil, function(_, fetch_err)
      if fetch_err then
        notify("PR を取り寄せられませんでした: " .. fetch_err, vim.log.levels.ERROR)
        return
      end
      open_diffview(st)
    end)

    run(st, { "gh", "pr", "diff", tostring(st.number), "--color", "never" }, nil, function(diff, diff_err)
      if diff_err then
        st.errors.diff = diff_err
      else
        st.diff_text = diff
        st.files = parse_diff(diff)
        st.hits = classify(st.files)
      end
      render_side(st)
      maybe_start_ai()
    end)

    -- {owner}/{repo} は gh が cwd のリポジトリから埋めてくれる
    run(st, { "gh", "api", "--paginate", "repos/{owner}/{repo}/pulls/" .. st.number .. "/comments" }, nil,
      function(comments, c_err)
        if not c_err then
          st.comments = decode(comments) or {}
          decorate_all(st)
        end
        maybe_start_ai()
      end)
  end)
end

-- ==========================================
-- コメント
-- ==========================================

-- コメント入力用のフローティングウィンドウ。<C-s> で on_submit(text) を呼ぶ
local function open_input(title, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local width = math.min(80, vim.o.columns - 4)
  local height = 8
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " <C-s> GitHubに投稿 / q 取り消し ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.cmd("startinsert")

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd("stopinsert")
    close()
    if text == "" then
      notify("空のコメントは投稿しませんでした")
      return
    end
    on_submit(text)
  end

  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "PR Review: コメントを投稿" })
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "PR Review: コメントを取り消し" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "PR Review: コメントを取り消し" })
end

-- カーソル行に対するレビューコメント（GitHub の差分の行に付く）
-- カーソル行に対するレビューコメント（GitHub の差分の行に付く）
--   diffview の左（base 側）なら LEFT、右（PR 側）なら RIGHT の行番号として送る
local function comment_on_line(st, buf)
  local info = st.bufs[buf]
  if not info then
    return
  end
  if not (st.pr and st.pr.headRefOid) then
    notify("PR情報の取得がまだ終わっていません", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path, side = info.path, info.side

  open_input(string.format("%s:%d にコメント（%s）", path, line, side == "LEFT" and "変更前" or "変更後"), function(text)
    run(st, {
      "gh", "api", "-X", "POST", "repos/{owner}/{repo}/pulls/" .. st.number .. "/comments",
      "-f", "body=" .. text,
      "-f", "commit_id=" .. st.pr.headRefOid,
      "-f", "path=" .. path,
      "-F", "line=" .. line,
      "-f", "side=" .. side,
    }, nil, function(out, err)
      if err then
        -- GitHub は差分（hunk）の範囲外の行へのコメントを受け付けない
        if err:find("422") or err:find("diff") then
          err = err .. "\n（変更箇所の近くの行でないとコメントできません）"
        end
        notify("コメントを投稿できませんでした: " .. err, vim.log.levels.ERROR)
        return
      end
      local created = decode(out)
      if created then
        st.comments = st.comments or {}
        table.insert(st.comments, created)
      end
      notify(string.format("%s:%d にコメントしました", path, line))
      decorate_all(st)
    end)
  end)
end

-- PR全体へのコメント（会話タブに付く）
local function comment_on_pr(st)
  open_input(string.format("#%d 全体にコメント", st.number), function(text)
    run(st, { "gh", "pr", "comment", tostring(st.number), "--body-file", "-" }, { stdin = text }, function(_, err)
      if err then
        notify("コメントを投稿できませんでした: " .. err, vim.log.levels.ERROR)
      else
        notify(string.format("#%d にコメントしました", st.number))
      end
    end)
  end)
end

-- ==========================================
-- 画面
-- ==========================================

local function current_view(st)
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if view and st.tab and view.tabpage == st.tab then
    return view
  end
  return nil
end

-- 手引きから、diffview のそのファイルへ移動する
local function jump_to_file(st, path)
  local view = current_view(st)
  if view then
    view:set_file_by_path(path, true)
  end
end

local function close(st)
  if st.tab and vim.api.nvim_tabpage_is_valid(st.tab) then
    vim.api.nvim_set_current_tabpage(st.tab)
    if current_view(st) then
      vim.cmd("DiffviewClose")
    elseif #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    end
  end
  if is_valid_buf(st.side_buf) then
    pcall(vim.api.nvim_buf_delete, st.side_buf, { force = true })
  end
end

-- 手引きのバッファを作る（diffview より先に作り、取得の進み具合を表示しておく）
local function create_side_buf(st)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ghpr-review"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "PR #" .. st.number .. " review")
  st.side_buf = buf

  vim.keymap.set("n", "<CR>", function()
    local item = st.side_map[vim.api.nvim_win_get_cursor(0)[1]]
    if item and item.path then
      jump_to_file(st, item.path)
    end
  end, { buffer = buf, nowait = true, desc = "PR Review: そのファイルの差分へ" })
  vim.keymap.set("n", "x", function()
    local item = st.side_map[vim.api.nvim_win_get_cursor(0)[1]]
    if item and item.viewpoint then
      st.checks[item.viewpoint] = not st.checks[item.viewpoint]
      render_side(st)
    end
  end, { buffer = buf, nowait = true, desc = "PR Review: 観点のチェックを切替" })
  vim.keymap.set("n", "q", function() close(st) end,
    { buffer = buf, nowait = true, desc = "PR Review: 閉じる" })
end

-- diffview でいま開いているファイルの左右のバッファに、コメント用のキーと既存コメントを付ける
--   左（base 側）は LEFT、右（PR 側）は RIGHT として GitHub の行に対応させる
local function attach_current(st)
  local view = current_view(st)
  local entry = view and view.panel.cur_file
  local layout = entry and entry.layout
  if not (layout and layout.a and layout.b) then
    return false
  end

  for _, pair in ipairs({ { layout.a, "LEFT" }, { layout.b, "RIGHT" } }) do
    local buf = pair[1].file and pair[1].file.bufnr
    if is_valid_buf(buf) then
      st.bufs[buf] = { path = entry.path, side = pair[2] }
      vim.keymap.set("n", "c", function() comment_on_line(st, buf) end,
        { buffer = buf, nowait = true, desc = "PR Review: この行にコメント" })
      vim.keymap.set("n", "C", function() comment_on_pr(st) end,
        { buffer = buf, nowait = true, desc = "PR Review: PR全体にコメント" })
      vim.keymap.set("n", "q", function() close(st) end,
        { buffer = buf, nowait = true, desc = "PR Review: 閉じる" })
      decorate_buf(st, buf)
    end
  end
  return true
end

-- 取り寄せた PR を diffview で開き、右端に手引きを並べる
open_diffview = function(st)
  local base = st.pr.baseRefName
  -- ... の3点は merge-base との比較（GitHub の「Files changed」と同じ範囲）
  vim.cmd(string.format("DiffviewOpen origin/%s...origin/pr/%d", base, st.number))
  st.tab = vim.api.nvim_get_current_tabpage()
  local diff_win = vim.api.nvim_get_current_win()

  vim.cmd("botright vertical " .. SIDE_WIDTH .. "split")
  st.side_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.side_win, st.side_buf)
  vim.wo[st.side_win].number = false
  vim.wo[st.side_win].relativenumber = false
  vim.wo[st.side_win].signcolumn = "no"
  vim.wo[st.side_win].foldcolumn = "0"
  vim.wo[st.side_win].cursorline = true
  vim.wo[st.side_win].wrap = true
  vim.wo[st.side_win].linebreak = true
  vim.wo[st.side_win].winfixwidth = true
  -- 手引きの分だけ右の差分が細くなるので、左右の差分の幅をそろえ直す
  vim.cmd("wincmd =")
  if vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
  end

  -- diffview がファイルを開くたびに、そのバッファへキーと既存コメントを付ける
  local group = vim.api.nvim_create_augroup("GitHubPrReview" .. st.number, { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = function()
      attach_current(st)
    end,
  })
  -- 最初のファイルは autocmd を登録する前に開かれていることがあるので、
  -- 準備ができるまで少し待って付ける
  local tries = 0
  local function attach_first()
    tries = tries + 1
    if not attach_current(st) and tries < 50 then
      vim.defer_fn(attach_first, 100)
    end
  end
  vim.schedule(attach_first)
  -- diffview を閉じたら後始末
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      if st.tab and vim.api.nvim_tabpage_is_valid(st.tab) then
        return
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
      for buf in pairs(st.bufs) do
        if is_valid_buf(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
      end
      if is_valid_buf(st.side_buf) then
        pcall(vim.api.nvim_buf_delete, st.side_buf, { force = true })
      end
    end,
  })
end

-- レビュー画面を開く
--   root: リポジトリのルート / pr: パネルの1件（number があればよい）
function M.open(root, pr)
  local st = {
    root = root,
    number = pr.number,
    ai = {},
    checks = {},
    errors = {},
    bufs = {},
    side_map = {},
  }
  create_side_buf(st)
  render_side(st)
  notify(string.format("#%d を取り寄せております…", st.number))
  fetch_all(st)
end

return M
