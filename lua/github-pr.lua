-- ==========================================
-- GitHub PR 一覧
-- ==========================================
-- 自分が作成した open PR と、自分がレビュワーに指定されている open PR を
-- セクションに分けて表示する。表示方法は2つ。
--
--   1. 常駐パネル    :GR / <leader>Gp
--        画面下部に水平分割で出しっぱなしにする。開いている間は自動で最新化される。
--        行で R を押すと差分とAIレビューの画面を開く（lua/github-pr-review.lua）
--   2. Telescope版   <leader>Gr / :GhReviewPRs
--        絞り込み検索したいときに使う。選んだら閉じる。
--
-- 更新の挙動（「随時更新」）:
--   * 開いた瞬間は前回のキャッシュを即表示（初回は「取得中…」）
--   * 裏で gh を非同期実行し、取得できたら表示を自動で差し替え
--   * 開いている間は REFRESH_INTERVAL_MS ごとに自動で再取得
--   * 手動更新もできる（パネルは r、Telescopeは <C-r>）
--   * 閉じるとタイマーは止まる（無駄なAPI消費を防ぐ）
--
-- 前提: gh CLI がインストール済みかつ `gh auth login` 済みであること

local M = {}

-- 表示中の自動再取得の間隔（ミリ秒）
local REFRESH_INTERVAL_MS = 30 * 1000
-- 常駐パネルの高さ（行）
local PANEL_HEIGHT = 14
-- 一度に取得するPRの最大件数（グループごと）
local PR_LIMIT = 50
-- gh から取り出すフィールド
local JSON_FIELDS = "number,title,author,url,updatedAt,isDraft,reviewDecision"

-- 取得するグループ。ここに書いた順にセクションとして表示する。
-- 同じPRが複数のグループに該当する場合（自分のPRにレビュー依頼が来ている等）は、
-- 先に書いたグループ側にだけ出す。
local GROUPS = {
  { key = "mine",   label = "自分のPR",     short = "自分", search = "author:@me" },
  { key = "review", label = "レビュー待ち", short = "依頼", search = "review-requested:@me" },
}

-- リポジトリのルートパスをキーにしたキャッシュ
--   cache[root] = {
--     groups = { { key, label, short, items = { <pr>, ... } }, ... },
--     fetched_at = <epoch秒>,
--   }
local cache = {}
-- 同一リポジトリへの多重fetchを防ぐフラグ
local inflight = {}

local ns = vim.api.nvim_create_namespace("github_pr_panel")

local function notify(msg, level)
  vim.notify("[GitHub PR] " .. msg, level or vim.log.levels.INFO)
end

-- ==========================================
-- 事前チェック
-- ==========================================

-- cwd から git のルートを特定する。git リポジトリでなければ nil を返す
local function git_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then
    return nil, "git リポジトリの中ではありません"
  end
  return out[1], nil
end

-- ==========================================
-- 取得（非同期）
-- ==========================================

-- GROUPS の各クエリを非同期で並行に叩き、全部揃ってから on_done(groups, err) で返す
-- 取得に成功したら cache[root] を更新する
local function fetch(root, on_done)
  -- すでに取得中なら何もしない（タイマーと手動更新が重なったときの二重叩き防止）
  if inflight[root] then
    return
  end
  inflight[root] = true

  local results = {}
  local first_err = nil
  local remaining = #GROUPS

  -- 全クエリが返ってきたところで、重複を除いてグループにまとめる
  local function finish()
    inflight[root] = nil

    if first_err then
      on_done(nil, first_err)
      return
    end

    local seen = {}
    local groups = {}
    for _, g in ipairs(GROUPS) do
      local items = {}
      for _, pr in ipairs(results[g.key] or {}) do
        -- 先に書いたグループが優先（例: 自分のPR に出たものは レビュー待ち には出さない）
        if not seen[pr.number] then
          seen[pr.number] = true
          table.insert(items, pr)
        end
      end
      -- 更新が新しい順に並べ替える（ISO8601なので文字列比較でよい）
      table.sort(items, function(a, b)
        return (a.updatedAt or "") > (b.updatedAt or "")
      end)
      table.insert(groups, { key = g.key, label = g.label, short = g.short, items = items })
    end

    cache[root] = { groups = groups, fetched_at = os.time() }
    on_done(groups, nil)
  end

  for _, g in ipairs(GROUPS) do
    vim.system({
      "gh", "pr", "list",
      "--search", g.search,
      "--state", "open",
      "--limit", tostring(PR_LIMIT),
      "--json", JSON_FIELDS,
    }, { cwd = root, text = true }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          local err = (obj.stderr or ""):gsub("%s+$", "")
          if err == "" then
            err = "gh の実行に失敗しました (exit " .. tostring(obj.code) .. ")"
          end
          first_err = first_err or err
        else
          local ok, decoded = pcall(vim.json.decode, obj.stdout)
          if ok and type(decoded) == "table" then
            results[g.key] = decoded
          else
            first_err = first_err or "gh の出力を解釈できませんでした"
          end
        end

        remaining = remaining - 1
        if remaining == 0 then
          finish()
        end
      end)
    end)
  end
end

-- キャッシュ1件分に入っているPRの総数
local function total_count(cached)
  local n = 0
  for _, g in ipairs(cached.groups or {}) do
    n = n + #g.items
  end
  return n
end

-- ==========================================
-- 表示の整形
-- ==========================================

-- "2026-09-15T02:30:00Z"（UTC） -> "2時間前"
local function relative_time(iso)
  if not iso then
    return ""
  end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  -- os.time はテーブルをローカル時刻として解釈するため、UTCとの差分を足して補正する
  local parsed = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    isdst = false,
  })
  local now = os.time()
  local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
  local diff = os.difftime(now, parsed + utc_offset)

  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return "たった今"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "分前"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "時間前"
  elseif diff < 86400 * 30 then
    return math.floor(diff / 86400) .. "日前"
  else
    return math.floor(diff / (86400 * 30)) .. "ヶ月前"
  end
end

-- PRの状態バッジと、その色（ハイライトグループ）を返す
local function status_badge(pr)
  if pr.isDraft then
    return "DRAFT", "TelescopeResultsComment"
  end
  local decision = pr.reviewDecision
  if decision == "APPROVED" then
    return "APPROVED", "DiagnosticOk"
  elseif decision == "CHANGES_REQUESTED" then
    return "CHANGES", "DiagnosticError"
  end
  -- REVIEW_REQUIRED もしくは空 = まだレビューされていない
  return "REVIEW", "DiagnosticWarn"
end

-- 1件分の表示文字列とハイライト範囲を組み立てる（パネルとTelescopeで共用）
-- 例: #1234 [APPROVED] ログイン画面のバリデーション修正   @tanaka 2時間前
-- prefix は Telescope 用のグループ印（例 "[自分] "）。パネルは見出しで分けるので渡さない。
local function format_pr(pr, prefix)
  prefix = prefix or ""
  local num = string.format("#%-5d", pr.number)
  local label, label_hl = status_badge(pr)
  local badge = string.format("[%-8s]", label)
  local title = pr.title or ""
  local author = "@" .. ((pr.author or {}).login or "unknown")
  local when = relative_time(pr.updatedAt)

  local display = prefix .. num .. " " .. badge .. " " .. title .. "  " .. author .. " " .. when

  -- ハイライトはバイトオフセット指定（日本語タイトルがあるので # でバイト長を取る）
  local off = #prefix
  local num_end = off + #num
  local badge_end = num_end + 1 + #badge
  local title_end = badge_end + 1 + #title

  local highlights = {
    { { off, num_end }, "TelescopeResultsNumber" },
    { { num_end + 1, badge_end }, label_hl },
    { { title_end, #display }, "TelescopeResultsComment" },
  }
  if off > 0 then
    table.insert(highlights, 1, { { 0, off }, "TelescopeResultsIdentifier" })
  end
  return display, highlights
end

-- 選択したPRをブラウザで開く
local function open_in_browser(root, pr)
  vim.system({ "gh", "pr", "view", tostring(pr.number), "--web" }, { cwd = root }, function(obj)
    if obj.code ~= 0 then
      local err = (obj.stderr or ""):gsub("%s+$", "")
      vim.schedule(function()
        notify("ブラウザを開けませんでした: " .. err, vim.log.levels.ERROR)
      end)
    end
  end)
end

-- ==========================================
-- 常駐パネル（画面下部の水平分割）
-- ==========================================

local panel = {
  buf = nil,
  win = nil,
  timer = nil,
  root = nil,
  -- パネル内の行番号(1始まり) -> PR
  line_map = {},
  -- 直近の取得エラー（表示中のみ保持）
  error = nil,
  -- 初回描画でカーソルを先頭PRへ移したかどうか
  cursor_initialized = false,
}

local augroup = vim.api.nvim_create_augroup("GitHubPrPanel", { clear = true })

local function panel_is_open()
  return panel.win ~= nil and vim.api.nvim_win_is_valid(panel.win)
end

local function panel_stop_timer()
  if panel.timer then
    panel.timer:stop()
    if not panel.timer:is_closing() then
      panel.timer:close()
    end
    panel.timer = nil
  end
end

-- パネルの中身を描き直す
local function panel_render()
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  local lines = {}
  -- { 行番号(0始まり), 開始col, 終了col(-1で行末), ハイライトグループ }
  local hls = {}
  panel.line_map = {}

  -- --- ヘッダー行 ---
  local cached = panel.root and cache[panel.root]
  local header
  if not cached then
    header = " GitHub PR — 取得中でございます…"
  else
    header = string.format(
      " GitHub PR — %d件 (%s 更新)",
      total_count(cached),
      os.date("%H:%M:%S", cached.fetched_at)
    )
  end
  local hint = "   [Enter]ブラウザで開く  [R]レビュー  [r]更新  [q]閉じる"
  table.insert(lines, header .. hint)
  table.insert(hls, { 0, 0, #header, "Title" })
  table.insert(hls, { 0, #header, -1, "Comment" })

  -- --- 本文 ---
  if panel.error then
    table.insert(lines, " 取得に失敗しました: " .. panel.error)
    table.insert(hls, { #lines - 1, 0, -1, "DiagnosticError" })
  elseif not cached then
    -- 初回取得が終わるまでは何も並べない
  else
    -- 見出しの罫線をウィンドウ幅いっぱいまで伸ばす
    local width = panel_is_open() and vim.api.nvim_win_get_width(panel.win) or 60

    for _, group in ipairs(cached.groups) do
      -- --- セクション見出し ---
      local label = string.format(" ── %s (%d) ", group.label, #group.items)
      local pad = width - vim.fn.strdisplaywidth(label) - 1
      local rule = pad > 0 and string.rep("─", pad) or ""
      table.insert(lines, label .. rule)
      local head0 = #lines - 1
      table.insert(hls, { head0, 0, #label, "Title" })
      if rule ~= "" then
        table.insert(hls, { head0, #label, -1, "Comment" })
      end

      -- --- セクションの中身 ---
      if #group.items == 0 then
        table.insert(lines, "   ありませんです")
        table.insert(hls, { #lines - 1, 0, -1, "Comment" })
      else
        for _, pr in ipairs(group.items) do
          local display, highlights = format_pr(pr)
          -- 左に1文字分の余白を入れて読みやすくする
          table.insert(lines, " " .. display)
          local lnum0 = #lines - 1
          panel.line_map[#lines] = pr
          for _, h in ipairs(highlights) do
            table.insert(hls, { lnum0, h[1][1] + 1, h[1][2] + 1, h[2] })
          end
        end
      end
    end
  end

  -- --- バッファへ反映（カーソル位置は保つ） ---
  local cursor
  if panel_is_open() then
    cursor = vim.api.nvim_win_get_cursor(panel.win)
  end

  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local end_col = h[3]
    if end_col == -1 then
      end_col = #lines[h[1] + 1]
    end
    pcall(vim.api.nvim_buf_set_extmark, panel.buf, ns, h[1], h[2], {
      end_col = end_col,
      hl_group = h[4],
    })
  end

  if cursor and panel_is_open() then
    cursor[1] = math.min(cursor[1], math.max(#lines, 1))
    -- 1行目はヘッダーなので、PRが並んだ最初の描画だけ先頭のPR行へ移す
    -- （以降はユーザーのカーソル位置を尊重し、自動更新で動かさない）
    if not panel.cursor_initialized and next(panel.line_map) ~= nil then
      local first
      for lnum in pairs(panel.line_map) do
        if not first or lnum < first then
          first = lnum
        end
      end
      cursor[1] = first
      panel.cursor_initialized = true
    end
    pcall(vim.api.nvim_win_set_cursor, panel.win, cursor)
  end
end

-- silent = true のときはエラーを表示しない（自動ポーリング用。オフライン時に画面を荒らさない）
local function panel_fetch(silent)
  if not panel.root then
    return
  end
  fetch(panel.root, function(items, err)
    if not panel_is_open() then
      return
    end
    if err then
      if not silent then
        panel.error = err
        panel_render()
      end
      return
    end
    panel.error = nil
    panel_render()
  end)
end

local function panel_close()
  local win = panel.win
  panel_stop_timer()
  panel.win = nil
  if win and vim.api.nvim_win_is_valid(win) then
    -- bufhidden=wipe なのでバッファもここで消える
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function panel_open()
  local root, root_err = git_root()
  if not root then
    notify(root_err, vim.log.levels.WARN)
    return
  end
  panel.root = root
  panel.error = nil
  panel.cursor_initialized = false

  -- 表示専用のスクラッチバッファ
  local buf = vim.api.nvim_create_buf(false, true)
  panel.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ghpr"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "GitHub PR")

  -- 画面下部に水平分割で開く
  vim.cmd("botright " .. PANEL_HEIGHT .. "split")
  local win = vim.api.nvim_get_current_win()
  panel.win = win
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  -- 他のウィンドウを開閉しても高さが変わらないように固定する
  vim.wo[win].winfixheight = true

  -- --- パネル内のキー操作 ---
  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local pr = panel.line_map[lnum]
    if pr then
      open_in_browser(panel.root, pr)
    end
  end, { buffer = buf, nowait = true, desc = "GitHub PR: ブラウザで開く" })

  vim.keymap.set("n", "R", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local pr = panel.line_map[lnum]
    if pr then
      require("github-pr-review").open(panel.root, pr)
    end
  end, { buffer = buf, nowait = true, desc = "GitHub PR: 差分とAIレビューを開く" })

  vim.keymap.set("n", "r", function()
    panel_fetch(false)
  end, { buffer = buf, nowait = true, desc = "GitHub PR: 手動更新" })

  vim.keymap.set("n", "q", function()
    panel_close()
  end, { buffer = buf, nowait = true, desc = "GitHub PR: パネルを閉じる" })

  -- --- 後始末とディレクトリ追従 ---
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      panel_stop_timer()
      panel.buf = nil
      panel.win = nil
    end,
  })

  -- project.nvim などで cwd が変わったら、その時点のリポジトリに切り替える
  vim.api.nvim_clear_autocmds({ group = augroup })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      if not panel_is_open() then
        return
      end
      local new_root = git_root()
      if new_root and new_root ~= panel.root then
        panel.root = new_root
        panel.error = nil
        panel_render()
        panel_fetch(true)
      end
    end,
  })

  -- キャッシュがあれば即座に描画され、待たされない
  panel_render()
  panel_fetch(false)

  panel.timer = vim.uv.new_timer()
  panel.timer:start(REFRESH_INTERVAL_MS, REFRESH_INTERVAL_MS, function()
    vim.schedule(function()
      if not panel_is_open() then
        panel_stop_timer()
        return
      end
      panel_fetch(true)
    end)
  end)
end

-- 常駐パネルを開く / 閉じる
function M.toggle_panel()
  if panel_is_open() then
    panel_close()
  else
    panel_open()
  end
end

function M.open_panel()
  if not panel_is_open() then
    panel_open()
  end
end

function M.close_panel()
  panel_close()
end

-- ==========================================
-- Telescope picker（絞り込み検索したいとき用）
-- ==========================================

-- picker のタイトル文字列（件数と最終更新時刻を出す）
local function picker_title(root)
  local cached = cache[root]
  if not cached then
    return "GitHub PR — 取得中…"
  end
  return string.format(
    "GitHub PR — %d件 (%s 更新)",
    total_count(cached),
    os.date("%H:%M:%S", cached.fetched_at)
  )
end

-- Telescope はセクション見出しを出せないので、グループ順に平らに並べ直す。
-- どのグループ由来かは行頭の印（[自分] / [依頼]）で分かるようにする。
local function flatten(groups)
  local out = {}
  for _, group in ipairs(groups or {}) do
    for _, pr in ipairs(group.items) do
      table.insert(out, { pr = pr, short = group.short, label = group.label })
    end
  end
  return out
end

-- entries が空のときは、選択できないプレースホルダ1件だけを並べる
local function make_finder(root, entries)
  local finders = require("telescope.finders")

  if #entries == 0 then
    local text = cache[root] and "対象のPRはありませんです" or "PR情報を取得中でございます…"
    return finders.new_table({
      results = { { placeholder = text } },
      entry_maker = function(x)
        return { value = x, display = x.placeholder, ordinal = x.placeholder }
      end,
    })
  end

  return finders.new_table({
    results = entries,
    entry_maker = function(e)
      local pr = e.pr
      local author = ((pr.author or {}).login or "")
      return {
        value = pr,
        prefix = "[" .. e.short .. "] ",
        display = function(entry)
          return format_pr(entry.value, entry.prefix)
        end,
        -- 検索対象: 番号・タイトル・作者・グループ名
        ordinal = table.concat({ tostring(pr.number), pr.title or "", author, e.label }, " "),
      }
    end,
  })
end

-- 自分のPR / レビュー待ちPR の一覧を Telescope で開く
function M.review_requested()
  if vim.fn.executable("gh") == 0 then
    notify("gh コマンドが見つかりません。`brew install gh` でインストールしてください", vim.log.levels.ERROR)
    return
  end

  local root, root_err = git_root()
  if not root then
    notify(root_err, vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- キャッシュがあれば、まずそれを即座に表示する（待たされない）
  local cached = cache[root]
  local initial_entries = flatten(cached and cached.groups)

  local prompt_bufnr_ref = nil
  local timer = nil

  local function stop_timer()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
  end

  -- 取得した結果を、開いている picker に反映する
  local function apply(groups)
    if not prompt_bufnr_ref or not vim.api.nvim_buf_is_valid(prompt_bufnr_ref) then
      -- すでに閉じられている
      stop_timer()
      return
    end
    local picker = action_state.get_current_picker(prompt_bufnr_ref)
    if not picker then
      return
    end
    -- reset_prompt = false にして、入力中の検索クエリを消さずに中身だけ差し替える
    picker:refresh(make_finder(root, flatten(groups)), { reset_prompt = false })
    if picker.prompt_border and picker.prompt_border.change_title then
      picker.prompt_border:change_title(picker_title(root))
    end
  end

  -- silent = true のときはエラーを通知しない（定期ポーリング用）
  local function do_fetch(silent)
    fetch(root, function(groups, err)
      if err then
        if not silent then
          notify(err, vim.log.levels.ERROR)
        end
        return
      end
      apply(groups)
    end)
  end

  pickers.new({}, {
    prompt_title = picker_title(root),
    finder = make_finder(root, initial_entries),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      prompt_bufnr_ref = prompt_bufnr

      -- picker が閉じられたらポーリングを止める
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = prompt_bufnr,
        once = true,
        callback = stop_timer,
      })

      -- Enter: ブラウザでPRを開く
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        -- プレースホルダ行（PRなし／取得中）は何もしない
        if not entry or not entry.value or not entry.value.number then
          return
        end
        actions.close(prompt_bufnr)
        open_in_browser(root, entry.value)
      end)

      -- <C-r>: 手動リフレッシュ
      map({ "i", "n" }, "<C-r>", function()
        do_fetch(false)
      end)

      return true
    end,
  }):find()

  -- 開いた直後に最新を取りに行く
  do_fetch(false)

  -- 表示している間は定期的に再取得する
  timer = vim.uv.new_timer()
  timer:start(REFRESH_INTERVAL_MS, REFRESH_INTERVAL_MS, function()
    vim.schedule(function()
      do_fetch(true)
    end)
  end)
end

-- ==========================================
-- セットアップ
-- ==========================================

function M.setup()
  -- :GR で常駐パネルを開閉する
  vim.api.nvim_create_user_command("GR", function()
    M.toggle_panel()
  end, { desc = "自分のPR / レビュー待ちPR の常駐パネルを開閉" })

  vim.api.nvim_create_user_command("GhReviewPRs", function()
    M.review_requested()
  end, { desc = "自分が作成した / レビュワーになっている open PR を Telescope で一覧表示" })
end

return M
