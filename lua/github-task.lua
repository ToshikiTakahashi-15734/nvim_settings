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
                repository { name }
                assignees(first: 10) { nodes { login } }
              }
              ... on PullRequest {
                number title url state
                repository { name }
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

-- cache["owner#番号"] = { title, sections = { { label, items } }, fetched_at }
local cache = {}
local inflight = {}

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
            local assignees = {}
            for _, a in ipairs(vim.tbl_get(c, "assignees", "nodes") or {}) do
              table.insert(assignees, a.login)
            end
            local status = node.status
            table.insert(items, {
              kind = c.__typename,
              number = c.number,
              title = c.title,
              url = c.url,
              state = c.state,
              repo = vim.tbl_get(c, "repository", "name"),
              assignees = assignees,
              status = (type(status) == "table" and status.name) or nil,
            })
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

-- 全セクションを並行に取り、揃ったら cache を更新して on_done(err)
local function fetch(setting, number, on_done)
  local key = cache_key(setting.owner, number)
  if inflight[key] then
    return
  end
  inflight[key] = true

  local sections = setting.sections or {}
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
    fetch_section(setting.owner, number, sec.query or "", function(items, t, err)
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

-- ==========================================
-- パネル（画面下部の水平分割）
-- ==========================================

local panel = {
  buf = nil,
  win = nil,
  setting = nil,
  number = nil,
  error = nil,
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
  local hint = "   [Enter]Webで開く [u]URLコピー [r]再取得 [p]プロジェクト切替 [q]閉じる"
  table.insert(lines, header .. hint)
  table.insert(hls, { 0, 0, #header, "Title" })
  table.insert(hls, { 0, #header, -1, "Comment" })

  if panel.error then
    table.insert(lines, " 取得に失敗しました: " .. panel.error)
    table.insert(hls, { #lines - 1, 0, -1, "DiagnosticError" })
  end

  if cached then
    local width = panel_is_open() and vim.api.nvim_win_get_width(panel.win) or 60

    -- バッジの幅を全アイテムで揃える
    local badge_width = 6
    for _, sec in ipairs(cached.sections) do
      for _, item in ipairs(sec.items) do
        badge_width = math.max(badge_width, vim.fn.strdisplaywidth((badge(item))))
      end
    end

    for _, sec in ipairs(cached.sections) do
      local label = string.format(" ── %s (%d)  %s ", sec.label, #sec.items, sec.query or "")
      local rest = width - vim.fn.strdisplaywidth(label) - 1
      table.insert(lines, label .. (rest > 0 and string.rep("─", rest) or ""))
      table.insert(hls, { #lines - 1, 0, -1, "Title" })

      if #sec.items == 0 then
        table.insert(lines, "   ありませんです")
        table.insert(hls, { #lines - 1, 0, -1, "Comment" })
      else
        for _, item in ipairs(sec.items) do
          local display, item_hls = format_item(item, badge_width)
          table.insert(lines, "  " .. display)
          panel.line_map[#lines] = item
          for _, h in ipairs(item_hls) do
            table.insert(hls, { #lines - 1, h[1] + 2, h[2] + 2, h[3] })
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

local function panel_fetch()
  panel.error = nil
  panel.inflight_label = true
  panel_render()
  local number = panel.number
  fetch(panel.setting, number, function(err)
    -- 取得中にプロジェクトを切り替えていたら、古い結果では描き直さない
    if number ~= panel.number then
      return
    end
    panel.inflight_label = nil
    panel.error = err
    if panel_is_open() then
      panel_render()
    end
  end)
end

local function current_item()
  return panel.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

-- 表示中のプロジェクトを切り替える
local function panel_switch(number)
  panel.number = number
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
