-- ==========================================
-- GitHub タスク一覧（Projects のissue）
-- ==========================================
-- GitHub Projects (v2) のアイテムを、Projects のビューと同じフィルタ構文で取得し、
-- セクションに分けて画面下部のパネルに表示する。
--
--   :task        設定ファイルのデフォルトプロジェクトを開く
--
-- パネル内のキー:
--   Enter … Webで開く / u … URLをコピー / r … 再取得 / p … プロジェクト切替 / q … 閉じる
--   f … 表示中の一覧を絞り込み（タイトル・番号・担当者など。空で解除）
--   t … 取得済みのタスクを Telescope であいまい検索（Enter でパネルのその行へカーソルを移す）
--   w … カーソル行のタスクで Ghostty の新しいウィンドウを開き、claude を起動
--   o … 子タスク（sub-issue）をツリーで開く / 閉じる（子の行でも押せば孫を開ける）
--        （~/develop/<リポジトリ名> で起動し、リンクと作業指示を渡す）
--   s … GitHub に条件を投げて検索（Projects のフィルタ構文。例: label:bug。空で解除）
--
-- 設定は ~/.config/nvim/task.setting.json に書く（:Task のたびに読み直すので再起動不要）:
--   owner           … プロジェクトの持ち主（組織名 or ユーザー名）
--   default_project … :Task で最初に開くプロジェクト番号
--   sections        … 表示するセクション。query は Projects のビューのフィルタと同じ書き方
--                     （例: "assignee:@me sprint:@current" / "no:parent-issue is:open"）
--
-- 前提: gh CLI が `project` スコープ付きでログイン済みであること
--   （足りなければ `gh auth refresh -s project`）

local M = {}

local SETTING_FILE = vim.fn.stdpath("config") .. "/task.setting.json"
-- 設定ファイルが無い・壊れているときに使う値
local DEFAULT_SETTING = {
  owner = "eustylelab",
  default_project = 15,
  sections = {
    { label = "今スプリントの自分のタスク", query = "assignee:@me sprint:@current" },
    { label = "親issueなし（open）", query = "no:parent-issue is:open" },
  },
}
-- パネルの高さ（行）
local PANEL_HEIGHT = 16
-- 1セクションで取得する最大ページ数（1ページ100件）
local MAX_PAGES = 10

-- items(query:) で Projects のビューと同じフィルタを効かせる。
-- repositoryOwner + ProjectV2Owner にしておくと、組織でも個人でも同じクエリで取れる。
local ITEMS_QUERY = [[
query($owner: String!, $number: Int!, $q: String!, $cursor: String) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $number) {
        title
        items(first: 100, after: $cursor, query: $q) {
          pageInfo { hasNextPage endCursor }
          nodes {
            status: fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
              __typename
              ... on Issue {
                number title url state
                repository { name owner { login } }
                assignees(first: 10) { nodes { login } }
                subIssuesSummary { total completed }
              }
              ... on PullRequest {
                number title url state
                repository { name owner { login } }
                assignees(first: 10) { nodes { login } }
              }
            }
          }
        }
      }
    }
  }
}
]]

-- 子タスク（sub-issue）を取る。Status はプロジェクトごとに違うので projectItems から拾う
local SUB_ISSUES_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      subIssues(first: 100) {
        nodes {
          number title url state
          repository { name owner { login } }
          assignees(first: 10) { nodes { login } }
          subIssuesSummary { total completed }
          projectItems(first: 10) {
            nodes {
              project { number }
              status: fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
            }
          }
        }
      }
    }
  }
}
]]

-- cache["owner#番号"] = { title, sections = { { label, items } }, fetched_at }
local cache = {}
local inflight = {}
-- 子タスクの取得結果。sub_cache[親のURL] = { loading = true } | { items = {...} } | { error = "…" }
local sub_cache = {}

local ns = vim.api.nvim_create_namespace("github_task_panel")

local function notify(msg, level)
  vim.notify("[Task] " .. msg, level or vim.log.levels.INFO)
end

-- ==========================================
-- 設定
-- ==========================================

local function load_setting()
  local setting = vim.deepcopy(DEFAULT_SETTING)
  local f = io.open(SETTING_FILE, "r")
  if not f then
    return setting
  end
  local text = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    notify("task.setting.json を読めませんでした。既定値で開きますです", vim.log.levels.WARN)
    return setting
  end
  return vim.tbl_extend("force", setting, decoded)
end

local function cache_key(owner, number)
  return owner .. "#" .. tostring(number)
end

-- ==========================================
-- 取得（非同期）
-- ==========================================

-- GraphQL の Issue / PullRequest を表示用のアイテムに変換する
local function to_item(c, status)
  local assignees = {}
  for _, a in ipairs(vim.tbl_get(c, "assignees", "nodes") or {}) do
    table.insert(assignees, a.login)
  end
  return {
    kind = c.__typename or "Issue",
    number = c.number,
    title = c.title,
    url = c.url,
    state = c.state,
    repo = vim.tbl_get(c, "repository", "name"),
    repo_owner = vim.tbl_get(c, "repository", "owner", "login"),
    assignees = assignees,
    status = status,
    sub_total = vim.tbl_get(c, "subIssuesSummary", "total") or 0,
    sub_done = vim.tbl_get(c, "subIssuesSummary", "completed") or 0,
  }
end

-- 1セクション分をページングしながら全部取る。on_done(items, title, err)
local function fetch_section(owner, number, query, on_done)
  local items = {}
  local title = nil
  local page = 0

  local function step(cursor)
    page = page + 1
    local cmd = {
      "gh", "api", "graphql",
      "-f", "query=" .. ITEMS_QUERY,
      "-f", "owner=" .. owner,
      "-F", "number=" .. tostring(number),
      "-f", "q=" .. query,
    }
    if cursor then
      table.insert(cmd, "-f")
      table.insert(cmd, "cursor=" .. cursor)
    end

    vim.system(cmd, { text = true }, function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          local err = (obj.stderr or ""):gsub("%s+$", "")
          on_done(nil, nil, err ~= "" and err or ("gh の実行に失敗しました (exit " .. obj.code .. ")"))
          return
        end
        local ok, decoded = pcall(vim.json.decode, obj.stdout)
        local project = ok
          and type(decoded) == "table"
          and vim.tbl_get(decoded, "data", "repositoryOwner", "projectV2")
        if not project or project == vim.NIL then
          on_done(nil, nil, "プロジェクト " .. owner .. "#" .. number .. " が見つかりませんでした")
          return
        end

        title = project.title
        for _, node in ipairs(project.items.nodes or {}) do
          local c = node.content
          -- DraftIssue（URLが無い）や権限の無いアイテムは除く
          if type(c) == "table" and c.url then
            local status = node.status
            table.insert(items, to_item(c, (type(status) == "table" and status.name) or nil))
          end
        end

        local info = project.items.pageInfo
        if info.hasNextPage and page < MAX_PAGES then
          step(info.endCursor)
        else
          on_done(items, title, nil)
        end
      end)
    end)
  end

  step(nil)
end

-- sections を並行に取り、揃ったら cache を更新して on_done(err)
local function fetch(owner, number, sections, on_done)
  local key = cache_key(owner, number)
  if inflight[key] then
    return
  end
  inflight[key] = true

  local results = {}
  local title = nil
  local first_err = nil
  local remaining = #sections

  if remaining == 0 then
    inflight[key] = nil
    on_done("task.setting.json の sections が空でございます")
    return
  end

  for i, sec in ipairs(sections) do
    fetch_section(owner, number, sec.query or "", function(items, t, err)
      if err then
        first_err = first_err or err
      else
        results[i] = { label = sec.label or sec.query, query = sec.query, items = items }
        title = title or t
      end
      remaining = remaining - 1
      if remaining == 0 then
        inflight[key] = nil
        if first_err then
          on_done(first_err)
          return
        end
        cache[key] = { title = title, sections = results, fetched_at = os.time() }
        on_done(nil)
      end
    end)
  end
end

-- ==========================================
-- 表示の整形
-- ==========================================

-- 状態バッジの文字とハイライト。閉じたものは state を優先して出す
local function badge(item)
  if item.state == "CLOSED" then
    return "CLOSED", "Comment"
  elseif item.state == "MERGED" then
    return "MERGED", "Comment"
  end
  local s = item.status or "-"
  local lower = s:lower()
  if lower:find("done") or s:find("完了") then
    return s, "DiagnosticOk"
  elseif lower:find("progress") or lower:find("review") or s:find("中") then
    return s, "DiagnosticWarn"
  end
  return s, "DiagnosticInfo"
end

-- 表示幅で右側を空白埋めする（日本語のステータス名でも列が揃うように）
local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  return w >= width and s or (s .. string.rep(" ", width - w))
end

-- 例: #15834 [In Progress ] タイトル  @user  zinger
local function format_item(item, badge_width)
  local num = string.format("#%-6s", tostring(item.number))
  if item.kind == "PullRequest" then
    num = string.format("PR%-5s", tostring(item.number))
  end
  local label, label_hl = badge(item)
  local b = "[" .. pad(label, badge_width) .. "]"
  local title = item.title or ""
  local who = #item.assignees > 0 and ("@" .. table.concat(item.assignees, ",@")) or "未アサイン"
  local tail = "  " .. who .. "  " .. (item.repo or "")

  local display = num .. " " .. b .. " " .. title .. tail
  local num_end = #num
  local b_end = num_end + 1 + #b
  local title_end = b_end + 1 + #title
  local title_hl = (item.state == "OPEN") and nil or "Comment"
  local hls = {
    { num_end - #num, num_end, "Number" },
    { num_end + 1, b_end, label_hl },
    { title_end, #display, "Comment" },
  }
  if title_hl then
    table.insert(hls, { b_end + 1, title_end, title_hl })
  end
  return display, hls
end

-- 絞り込み・Telescope の検索対象にする文字列（番号・タイトル・担当者・リポジトリ・ステータス）
local function search_text(item)
  return table.concat({
    "#" .. tostring(item.number),
    item.title or "",
    table.concat(item.assignees, " "),
    item.repo or "",
    item.status or "",
  }, " ")
end

-- 絞り込み文字列に一致するか（空白区切りの全語を含むものだけ残す。大文字小文字は区別しない）
local function match_filter(item, filter)
  if not filter or filter == "" then
    return true
  end
  local text = search_text(item):lower()
  for word in filter:lower():gmatch("%S+") do
    if not text:find(word, 1, true) then
      return false
    end
  end
  return true
end

-- ==========================================
-- パネル（画面下部の水平分割）
-- ==========================================

local panel = {
  buf = nil,
  win = nil,
  setting = nil,
  number = nil,
  error = nil,
  -- f で入力した絞り込み文字列（表示中の一覧だけを絞る）
  filter = nil,
  -- s で入力した GitHub への検索条件（「検索結果」セクションとして取得する）
  search = nil,
  -- o で開いている親タスク。expanded[URL] = true
  expanded = {},
  -- パネル内の行番号(1始まり) -> アイテム
  line_map = {},
}

local function panel_is_open()
  return panel.win ~= nil and vim.api.nvim_win_is_valid(panel.win)
end

local function panel_render()
  if not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then
    return
  end

  local lines = {}
  -- { 行(0始まり), 開始col, 終了col(-1で行末), ハイライト }
  local hls = {}
  panel.line_map = {}

  local cached = cache[cache_key(panel.setting.owner, panel.number)]
  local name = (cached and cached.title or "") .. " (" .. panel.setting.owner .. "#" .. panel.number .. ")"
  local header
  if panel.inflight_label then
    header = " Task — " .. name .. " 取得中でございます…"
  elseif cached then
    header = string.format(" Task — %s  %s 更新", name, os.date("%H:%M:%S", cached.fetched_at))
  else
    header = " Task — " .. name
  end
  local hint = "   [Enter]Webで開く [o]子タスク開閉 [u]URLコピー [f]絞り込み [t]Telescope [w]claude起動 [s]GitHub検索 [r]再取得 [p]プロジェクト切替 [q]閉じる"
  table.insert(lines, header .. hint)
  table.insert(hls, { 0, 0, #header, "Title" })
  table.insert(hls, { 0, #header, -1, "Comment" })

  if panel.filter then
    table.insert(lines, " 絞り込み中: " .. panel.filter .. "   （f で空にすると解除）")
    table.insert(hls, { #lines - 1, 0, -1, "DiagnosticWarn" })
  end

  if panel.error then
    table.insert(lines, " 取得に失敗しました: " .. panel.error)
    table.insert(hls, { #lines - 1, 0, -1, "DiagnosticError" })
  end

  if cached then
    local width = panel_is_open() and vim.api.nvim_win_get_width(panel.win) or 60

    -- 開いている子タスクも含めて、表示する行を先に並べる
    --   row = { item = …, tree = "├ " などの罫線 } / { note = "取得中…", tree = … }
    local function collect(items, cont, rows)
      for i, item in ipairs(items) do
        local last = (i == #items)
        local tree = cont == nil and "" or (cont .. (last and "└ " or "├ "))
        table.insert(rows, { item = item, tree = tree })
        if panel.expanded[item.url] then
          -- 子の罫線は親の ▸ の1つ右の列に出す（親の兄弟が続くなら │ で線をつなぐ）
          local child_cont = cont == nil and "  " or (cont .. (last and "  " or "│ ") .. "  ")
          local sub = sub_cache[item.url]
          if not sub or sub.loading then
            table.insert(rows, { note = "取得中でございます…", tree = child_cont .. "└ " })
          elseif sub.error then
            table.insert(rows, { note = "取得に失敗しました: " .. sub.error, tree = child_cont .. "└ ", hl = "DiagnosticError" })
          else
            collect(sub.items, child_cont, rows)
          end
        end
      end
      return rows
    end

    local section_rows = {}
    -- バッジの幅を全行で揃える
    local badge_width = 6
    for i, sec in ipairs(cached.sections) do
      local items = vim.tbl_filter(function(item)
        return match_filter(item, panel.filter)
      end, sec.items)
      section_rows[i] = { items = items, rows = collect(items, nil, {}) }
      for _, row in ipairs(section_rows[i].rows) do
        if row.item then
          badge_width = math.max(badge_width, vim.fn.strdisplaywidth((badge(row.item))))
        end
      end
    end

    for i, sec in ipairs(cached.sections) do
      local items = section_rows[i].items
      local count = panel.filter and string.format("%d/%d", #items, #sec.items) or tostring(#sec.items)
      local label = string.format(" ── %s (%s)  %s ", sec.label, count, sec.query or "")
      local rest = width - vim.fn.strdisplaywidth(label) - 1
      table.insert(lines, label .. (rest > 0 and string.rep("─", rest) or ""))
      table.insert(hls, { #lines - 1, 0, -1, "Title" })

      if #items == 0 then
        table.insert(lines, "   ありませんです")
        table.insert(hls, { #lines - 1, 0, -1, "Comment" })
      else
        for _, row in ipairs(section_rows[i].rows) do
          if row.note then
            local head = "  " .. row.tree
            table.insert(lines, head .. row.note)
            table.insert(hls, { #lines - 1, 0, #head, "Comment" })
            table.insert(hls, { #lines - 1, #head, -1, row.hl or "Comment" })
          else
            local item = row.item
            -- 子タスクがあるものは ▸（閉）/ ▾（開）を付け、末尾に「子 完了/全体」を出す
            local mark = "  "
            if item.sub_total > 0 then
              mark = panel.expanded[item.url] and "▾ " or "▸ "
            end
            local head = "  " .. row.tree .. mark
            local display, item_hls = format_item(item, badge_width)
            local sub = item.sub_total > 0 and string.format("  子 %d/%d", item.sub_done, item.sub_total) or ""
            table.insert(lines, head .. display .. sub)
            panel.line_map[#lines] = item
            table.insert(hls, { #lines - 1, 0, #head, "Comment" })
            for _, h in ipairs(item_hls) do
              table.insert(hls, { #lines - 1, h[1] + #head, h[2] + #head, h[3] })
            end
            if sub ~= "" then
              local sub_hl = item.sub_done == item.sub_total and "DiagnosticOk" or "DiagnosticWarn"
              table.insert(hls, { #lines - 1, #head + #display, -1, sub_hl })
            end
          end
        end
      end
    end
  end

  local cursor = panel_is_open() and vim.api.nvim_win_get_cursor(panel.win) or nil

  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local end_col = h[3] == -1 and #lines[h[1] + 1] or h[3]
    pcall(vim.api.nvim_buf_set_extmark, panel.buf, ns, h[1], h[2], { end_col = end_col, hl_group = h[4] })
  end

  if cursor and panel_is_open() then
    -- 1行目（ヘッダー）にいるときは最初のアイテムへ移す
    if cursor[1] == 1 then
      for lnum = 1, #lines do
        if panel.line_map[lnum] then
          cursor[1] = lnum
          break
        end
      end
    end
    cursor[1] = math.min(cursor[1], math.max(#lines, 1))
    pcall(vim.api.nvim_win_set_cursor, panel.win, cursor)
  end
end

local function fetch_sub_issues(item)
  sub_cache[item.url] = { loading = true }
  vim.system({
    "gh", "api", "graphql",
    "-f", "query=" .. SUB_ISSUES_QUERY,
    "-f", "owner=" .. (item.repo_owner or panel.setting.owner),
    "-f", "repo=" .. (item.repo or ""),
    "-F", "number=" .. tostring(item.number),
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        sub_cache[item.url] = { error = (obj.stderr or ""):gsub("%s+$", "") }
      else
        local ok, decoded = pcall(vim.json.decode, obj.stdout)
        local nodes = ok and type(decoded) == "table"
          and vim.tbl_get(decoded, "data", "repository", "issue", "subIssues", "nodes")
        if type(nodes) ~= "table" then
          sub_cache[item.url] = { error = "gh の出力を解釈できませんでした" }
        else
          local items = {}
          for _, c in ipairs(nodes) do
            -- 表示中のプロジェクトでの Status を使う（そのプロジェクトに無い子は「-」）
            local status = nil
            for _, pi in ipairs(vim.tbl_get(c, "projectItems", "nodes") or {}) do
              if vim.tbl_get(pi, "project", "number") == panel.number and type(pi.status) == "table" then
                status = pi.status.name
              end
            end
            table.insert(items, to_item(c, status))
          end
          sub_cache[item.url] = { items = items }
        end
      end
      if panel_is_open() then
        panel_render()
      end
    end)
  end)
end

-- 開いている親タスクの子を取り直す
local function refetch_expanded()
  for url in pairs(sub_cache) do
    if not panel.expanded[url] then
      sub_cache[url] = nil
    end
  end
  local function walk(items)
    for _, item in ipairs(items or {}) do
      if panel.expanded[item.url] then
        local sub = sub_cache[item.url]
        if not (sub and sub.loading) then
          fetch_sub_issues(item)
        end
      end
    end
  end
  local cached = cache[cache_key(panel.setting.owner, panel.number)]
  for _, sec in ipairs(cached and cached.sections or {}) do
    walk(sec.items)
  end
  for _, sub in pairs(vim.deepcopy(sub_cache)) do
    walk(sub.items)
  end
end

local function panel_fetch()
  panel.error = nil
  panel.inflight_label = true
  panel_render()
  local number = panel.number
  -- GitHub 検索中は「検索結果」セクションを先頭に足して一緒に取る
  local sections = vim.list_extend({}, panel.setting.sections or {})
  if panel.search then
    table.insert(sections, 1, { label = "検索結果", query = panel.search })
  end
  fetch(panel.setting.owner, number, sections, function(err)
    -- 取得中にプロジェクトを切り替えていたら、古い結果では描き直さない
    if number ~= panel.number then
      return
    end
    panel.inflight_label = nil
    panel.error = err
    if panel_is_open() then
      panel_render()
      if not err then
        refetch_expanded()
      end
    end
  end)
end

local function current_item()
  return panel.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

-- 表示中のプロジェクトを切り替える
local function panel_switch(number)
  panel.number = number
  panel.expanded = {}
  sub_cache = {}
  panel.error = nil
  panel_render()
  panel_fetch()
end

-- owner のプロジェクト一覧から選んで切り替える
local function pick_project()
  local owner = panel.setting.owner
  notify("プロジェクト一覧を取得中でございます…")
  vim.system({
    "gh", "project", "list", "--owner", owner, "--format", "json", "--limit", "100",
  }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        notify("プロジェクト一覧を取得できませんでした: " .. (obj.stderr or ""), vim.log.levels.ERROR)
        return
      end
      local ok, decoded = pcall(vim.json.decode, obj.stdout)
      local projects = ok and type(decoded) == "table" and decoded.projects or {}
      projects = vim.tbl_filter(function(p)
        return not p.closed
      end, projects)
      table.sort(projects, function(a, b)
        return a.number > b.number
      end)

      vim.ui.select(projects, {
        prompt = owner .. " のプロジェクト",
        format_item = function(p)
          local mark = (p.number == panel.setting.default_project) and "  (デフォルト)" or ""
          local now = (p.number == panel.number) and "  ← 表示中" or ""
          return string.format("#%-3d %s%s%s", p.number, p.title, mark, now)
        end,
      }, function(choice)
        if choice and panel_is_open() then
          panel_switch(choice.number)
        end
      end)
    end)
  end)
end

-- f: 表示中の一覧を絞り込む（空で解除）
local function prompt_filter()
  vim.ui.input({ prompt = "絞り込み: ", default = panel.filter or "" }, function(input)
    if input == nil then
      return
    end
    panel.filter = (input ~= "" and input) or nil
    panel_render()
  end)
end

-- s: GitHub に条件を投げて検索する（空で解除）
local function prompt_search()
  vim.ui.input({ prompt = "GitHub検索（例: label:bug is:open）: ", default = panel.search or "" }, function(input)
    if input == nil then
      return
    end
    panel.search = (input ~= "" and input) or nil
    panel_fetch()
  end)
end

-- o: 子タスクをツリーで開く / 閉じる
local function toggle_children()
  local item = current_item()
  if not item then
    return
  end
  if item.sub_total == 0 then
    notify("#" .. item.number .. " には子タスクがありませんです")
    return
  end
  if panel.expanded[item.url] then
    panel.expanded[item.url] = nil
  else
    panel.expanded[item.url] = true
    local sub = sub_cache[item.url]
    if not sub or sub.error then
      fetch_sub_issues(item)
    end
  end
  panel_render()
end

-- パネル内で url の行へカーソルを移す。絞り込みで隠れていたら絞り込みを解除して探し直す
local function jump_to(url)
  if not panel_is_open() then
    return
  end
  local function find()
    for lnum, item in pairs(panel.line_map) do
      if item.url == url then
        return lnum
      end
    end
  end
  local lnum = find()
  if not lnum and panel.filter then
    panel.filter = nil
    panel_render()
    lnum = find()
  end
  vim.api.nvim_set_current_win(panel.win)
  if lnum then
    vim.api.nvim_win_set_cursor(panel.win, { lnum, 0 })
  end
end

-- t: 取得済みのタスクを Telescope であいまい検索する（Enter でパネルのその行へカーソルを移す）
local function telescope_search()
  local cached = cache[cache_key(panel.setting.owner, panel.number)]
  if not cached then
    notify("まだ取得できておりませんです。少しお待ちくださいです", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- 複数セクションに出るアイテムは1回だけ並べる
  local entries, seen = {}, {}
  for _, sec in ipairs(cached.sections) do
    for _, item in ipairs(sec.items) do
      if not seen[item.url] then
        seen[item.url] = true
        table.insert(entries, { item = item, section = sec.label })
      end
    end
  end

  pickers.new({}, {
    prompt_title = "Task — " .. (cached.title or ""),
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        local display = format_item(e.item, 12)
        return {
          value = e.item,
          display = "[" .. e.section .. "] " .. display,
          ordinal = e.section .. " " .. search_text(e.item),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          jump_to(entry.value.url)
        end
      end)
      return true
    end,
  }):find()
end

-- w: カーソル行のタスクで Ghostty の新しいウィンドウを開き、claude を起動する
local function start_claude()
  local item = current_item()
  if not item then
    return
  end
  -- リポジトリは ~/develop/<リポジトリ名> にある前提。無ければ今のディレクトリで起動する
  local dir = vim.fn.expand("~/develop/") .. (item.repo or "")
  if not item.repo or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end
  local prompt = item.url .. "\nワークフロー開始\n並行して作業しているので干渉しないようにして"
  -- いつものシェルに打ち込む形で起動する（$'…' で改行入りの指示を1行で渡す）
  local input = "claude $'" .. prompt:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n") .. "'\n"

  vim.system({
    "osascript",
    "-e", "on run argv",
    "-e", 'tell application "Ghostty"',
    "-e", "set cfg to new surface configuration",
    "-e", "set initial working directory of cfg to item 1 of argv",
    "-e", "set initial input of cfg to item 2 of argv",
    "-e", "new window with configuration cfg",
    "-e", "activate",
    "-e", "end tell",
    "-e", "end run",
    dir, input,
  }, { text = true }, function(obj)
    if obj.code ~= 0 then
      vim.schedule(function()
        notify("Ghostty を開けませんでした: " .. (obj.stderr or ""), vim.log.levels.ERROR)
      end)
    end
  end)
end

local function panel_close()
  if panel_is_open() then
    -- bufhidden=wipe なのでバッファも一緒に消える
    pcall(vim.api.nvim_win_close, panel.win, true)
  end
  panel.win = nil
end

local function panel_open()
  local buf = vim.api.nvim_create_buf(false, true)
  panel.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ghtask"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "GitHub Task")

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
  vim.wo[win].winfixheight = true

  -- --- パネル内のキー操作 ---
  vim.keymap.set("n", "<CR>", function()
    local item = current_item()
    if item then
      vim.ui.open(item.url)
    end
  end, { buffer = buf, nowait = true, desc = "Task: Webで開く" })

  vim.keymap.set("n", "o", toggle_children, { buffer = buf, nowait = true, desc = "Task: 子タスクを開閉" })

  vim.keymap.set("n", "u", function()
    local item = current_item()
    if item then
      vim.fn.setreg("+", item.url)
      vim.fn.setreg('"', item.url)
      notify("URLをコピーしましたです: " .. item.url)
    end
  end, { buffer = buf, nowait = true, desc = "Task: URLをコピー" })

  vim.keymap.set("n", "r", panel_fetch, { buffer = buf, nowait = true, desc = "Task: 再取得" })
  vim.keymap.set("n", "p", pick_project, { buffer = buf, nowait = true, desc = "Task: プロジェクト切替" })
  vim.keymap.set("n", "f", prompt_filter, { buffer = buf, nowait = true, desc = "Task: 一覧を絞り込み" })
  vim.keymap.set("n", "t", telescope_search, { buffer = buf, nowait = true, desc = "Task: Telescopeで検索" })
  vim.keymap.set("n", "w", start_claude, { buffer = buf, nowait = true, desc = "Task: 新しいターミナルでclaudeを起動" })
  vim.keymap.set("n", "s", prompt_search, { buffer = buf, nowait = true, desc = "Task: GitHubに条件を投げて検索" })
  vim.keymap.set("n", "q", panel_close, { buffer = buf, nowait = true, desc = "Task: 閉じる" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      panel.buf = nil
      panel.win = nil
    end,
  })
end

-- パネルを開く（開いていればフォーカスする）。設定ファイルの default_project を開く
function M.open()
  if vim.fn.executable("gh") == 0 then
    notify("gh コマンドが見つかりません。`brew install gh` でインストールしてください", vim.log.levels.ERROR)
    return
  end

  panel.setting = load_setting()
  panel.number = panel.setting.default_project
  panel.error = nil

  if panel_is_open() then
    vim.api.nvim_set_current_win(panel.win)
  else
    panel_open()
  end
  -- キャッシュがあれば即表示し、裏で最新を取りに行く
  panel_render()
  panel_fetch()
end

-- ==========================================
-- セットアップ
-- ==========================================

function M.setup()
  vim.api.nvim_create_user_command("Task", function()
    M.open()
  end, { desc = "GitHub Projects のタスク一覧パネルを開く（:task でも可）" })

  -- ユーザーコマンドは大文字始まりしか作れないので、:task を :Task に読み替える
  -- （コマンドラインの先頭で task と打ったときだけ置き換わる）
  vim.cmd([[cnoreabbrev <expr> task (getcmdtype() ==# ':' && getcmdline() ==# 'task') ? 'Task' : 'task']])
end

return M
