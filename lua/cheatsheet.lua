-- ==========================================
-- コマンド集（チートシート）
-- ==========================================
-- 以下の4つをタブに分けて、1つのフローティングウィンドウで表示する。
--
--   1. 備忘録      lua/.keys に手書きしているショートカット備忘録
--                  （シェルの keys / edkey と同じファイルなので、編集すると即反映）
--   2. キーマップ  いま Neovim に登録されているキーマップ
--   3. コマンド    ユーザー定義コマンド（:GR, :Lazy など）
--   4. スニペット  LuaSnip に登録されているスニペット
--
-- キーマップとコマンドは開くたびに Neovim から読み直し、定義した場所ごとに
-- 自動で分類する（手で一覧を書く必要はない）:
--   * keymaps.lua で定義 → その上にある「-- ====」見出しごと
--   * lua/plugins/X.lua や lazy の keys / cmd で定義 → X ごと
--   * lua/X.lua で定義 → X ごと
--   * Neovim が最初から持っているもの → 「Neovim 標準」（いちばん下）
-- つまり、keymaps.lua の見出しの下にキーマップを書いたり、プラグインを足したり
-- するだけで、ここにも自動で反映される。
--
-- 開き方: :Cheatsheet / <leader>H
--   :Cheatsheet search  でいきなり Telescope の横断検索を開く
--
-- ウィンドウ内の操作:
--   <Tab> / <S-Tab> / 1-4 : タブ切替
--   /                     : 全タブ横断で絞り込み検索（Telescope）
--   <Enter>               : キーマップなら実行、コマンドならコマンドラインに入力
--   e                     : 備忘録（lua/.keys）を編集
--   q / <Esc>             : 閉じる

local M = {}

local KEYS_FILE = vim.fn.stdpath("config") .. "/lua/.keys"
-- キーマップを集めるモード（表示順）
local MODES = {
  { mode = "n", label = "ノーマル" },
  { mode = "x", label = "ビジュアル" },
  { mode = "i", label = "インサート" },
  { mode = "t", label = "ターミナル" },
}
local TABS = {
  { key = "memo",    label = "備忘録" },
  { key = "keymaps", label = "キーマップ" },
  { key = "cmds",    label = "コマンド" },
  { key = "snips",   label = "スニペット" },
}
-- キー列の表示幅
local KEY_WIDTH = 22

local ns = vim.api.nvim_create_namespace("cheatsheet")

-- 表示中ウィンドウの状態（閉じたら nil）
local state = nil

-- ==========================================
-- データ収集
-- ==========================================
-- どのソースも次の形のエントリ配列を返す:
--   { section = <見出し>, key = <キー or nil>, desc = <説明>, run = <function or nil> }
-- key が nil のエントリは「説明だけの行」として扱う。

-- " : " で「キー」と「説明」に分ける。分けられなければ nil, 行全体
local function split_key_desc(line)
  local key, desc = line:match("^(.-)%s+:%s*(.*)$")
  if key and key ~= "" and vim.fn.strdisplaywidth(key) <= 40 then
    return key, desc
  end
  return nil, line
end

-- lua/.keys の alias keys='echo "…"' の中身を読み取る
local function collect_memo()
  local entries = {}
  if vim.fn.filereadable(KEYS_FILE) == 0 then
    table.insert(entries, { section = "備忘録", desc = KEYS_FILE .. " が見つかりません" })
    return entries
  end

  local inside = false
  local section = "備忘録"
  local sub = nil
  for _, raw in ipairs(vim.fn.readfile(KEYS_FILE)) do
    if not inside then
      if raw:match("^alias keys='echo \"") then
        inside = true
      end
    elseif raw:match("^\"'") then
      break
    else
      -- 全角スペースのインデントも普通のスペース扱いにする
      local line = vim.trim((raw:gsub("　", " ")))
      if line:match("^■") then
        section = vim.trim(line:gsub("^■", ""))
        sub = nil
      elseif line:match("^#") then
        sub = vim.trim(line:gsub("^#", ""))
        table.insert(entries, { section = section, subheading = sub })
      elseif line ~= "" and not line:match("^📌") and not line:match("^%-%-%-") and not line:match("^💡") then
        local key, desc = split_key_desc(line)
        table.insert(entries, {
          section = section,
          sub = sub,
          key = key,
          desc = desc,
        })
      end
    end
  end
  return entries
end

-- Neovim は内部で 0x80 のバイトを「0x80 0xFE 'X'」にエスケープして持っていて、
-- nvim_get_commands の definition などはそのまま返してくる。
-- 「、」(E3 80 81) のように 0x80 を含む文字が化けるので元に戻す。
local function unescape(s)
  return (s:gsub("\128\254X", "\128"))
end

local function keytrans(lhs)
  local ok, s = pcall(vim.fn.keytrans, vim.api.nvim_replace_termcodes(lhs, true, true, true))
  return ok and s or lhs
end

-- vim.keymap.set に渡された lhs を nvim_get_keymap が返す形にそろえる
-- （<leader> を実際のキーに展開してから表記を正規化する）
local function normalize_lhs(lhs)
  local leader = vim.g.mapleader or "\\"
  local localleader = vim.g.maplocalleader or "\\"
  lhs = lhs:gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function() return leader end)
  lhs = lhs:gsub("<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>", function() return localleader end)
  return keytrans(lhs)
end

-- ==========================================
-- 定義元の記録
-- ==========================================
-- キーマップやコマンドが「どのファイルの何行目で」作られたかを覚えておき、
-- 一覧をファイル・見出しごとに自動でまとめるのに使う。
-- 新しくキーマップやプラグインを足しても、書いた場所から分類が決まるので
-- 備忘録を手で書き直さなくても一覧に反映される。
--
-- init.lua の先頭（keymaps より前）で M.track() を呼んでおくこと。

-- origins.keymaps["g|n| f"] = { src = <ファイル>, line = <行> }（buffer ローカルは "b|…"）
-- origins.cmds["Table"]      = { src = <ファイル>, line = <行> }
local origins = { keymaps = {}, cmds = {} }

local function caller()
  local info = debug.getinfo(3, "Sl")
  if info and info.source and info.source:sub(1, 1) == "@" then
    return { src = info.source:sub(2), line = info.currentline }
  end
  return nil
end

function M.track()
  if M._tracking then
    return
  end
  M._tracking = true

  local orig_set = vim.keymap.set
  vim.keymap.set = function(mode, lhs, rhs, opts)
    local where = caller()
    if where and type(lhs) == "string" then
      local scope = (opts and opts.buffer) and "b" or "g"
      local modes = type(mode) == "table" and mode or { mode }
      for _, m in ipairs(modes) do
        -- "" / "v" はノーマル・ビジュアル両方に効くので両方に記録する
        local expanded = (m == "" and { "n", "x", "o" }) or (m == "v" and { "x", "s" }) or { m }
        for _, em in ipairs(expanded) do
          origins.keymaps[scope .. "|" .. em .. "|" .. normalize_lhs(lhs)] = where
        end
      end
    end
    return orig_set(mode, lhs, rhs, opts)
  end

  local orig_cmd = vim.api.nvim_create_user_command
  vim.api.nvim_create_user_command = function(name, command, opts)
    local where = caller()
    if where then
      origins.cmds[name] = where
    end
    return orig_cmd(name, command, opts)
  end
end

-- ==========================================
-- 定義元 → 分類名
-- ==========================================

local CONFIG_DIR = vim.fn.resolve(vim.fn.stdpath("config"))
local KEYMAPS_FILE = CONFIG_DIR .. "/lua/keymaps.lua"

-- 分類の並び順（小さいほど上）
local RANK_KEYMAPS = 1  -- keymaps.lua の見出し（ファイル内の順）
local RANK_CONFIG = 2   -- lua/*.lua, lua/plugins/*.lua
local RANK_PLUGIN = 3   -- 外部プラグインが自分で登録したもの
local RANK_BUILTIN = 9  -- Neovim 標準

-- keymaps.lua の「-- ====」で囲まれた見出しを { line, title } の配列で返す
local function keymaps_headings()
  local headings = {}
  if vim.fn.filereadable(KEYMAPS_FILE) == 0 then
    return headings
  end
  local lines = vim.fn.readfile(KEYMAPS_FILE)
  for i = 1, #lines - 2 do
    if lines[i]:match("^%-%- ====") and lines[i + 2]:match("^%-%- ====") then
      local title = vim.trim(lines[i + 1]:gsub("^%-%-", ""))
      table.insert(headings, { line = i + 1, title = title })
    end
  end
  return headings
end

local function lazy_plugins()
  local ok, config = pcall(require, "lazy.core.config")
  return ok and config.plugins or {}
end

-- lazy.nvim のプラグイン名 → それを書いている lua/plugins/<名前>.lua の <名前>
-- （"catppuccin/nvim" のように名前とリポジトリ名が違うこともあるので、
--   各プラグインの "owner/repo" がどのファイルに書かれているかで探す）
local function plugin_spec_files()
  local texts = {}
  for _, file in ipairs(vim.fn.glob(CONFIG_DIR .. "/lua/plugins/*.lua", false, true)) do
    texts[vim.fn.fnamemodify(file, ":t:r")] = table.concat(vim.fn.readfile(file), "\n")
  end
  local stems = vim.tbl_keys(texts)
  table.sort(stems)

  local map = {}
  for name, plugin in pairs(lazy_plugins()) do
    local repo = plugin[1]
    if type(repo) == "string" then
      -- 本体として書いているファイルでは、たいてい先頭近くに出てくる。
      -- dependencies として書かれているだけのファイルより、出現位置が早い方を選ぶ。
      local best_pos
      for _, stem in ipairs(stems) do
        local text = texts[stem]
        local pos = text:find('"' .. repo .. '"', 1, true) or text:find("'" .. repo .. "'", 1, true)
        if pos and (not best_pos or pos < best_pos) then
          best_pos = pos
          map[name] = stem
        end
      end
    end
  end
  return map
end

-- require("xxx") の xxx を持っているプラグインを探す
-- （vim.cmd("command! …") で作られたコマンドは定義元が取れないので、中身から推測する）
local function plugin_by_module(definition)
  local mod = definition and definition:match("require%s*%(?%s*[\"']([%w_%-]+)")
  if not mod then
    return nil
  end
  for name, plugin in pairs(lazy_plugins()) do
    if plugin.dir and (vim.fn.isdirectory(plugin.dir .. "/lua/" .. mod) == 1
        or vim.fn.filereadable(plugin.dir .. "/lua/" .. mod .. ".lua") == 1) then
      return name
    end
  end
  return nil
end

-- lazy.nvim の keys / cmd 指定から「どのプラグインのものか」を引く表
local function lazy_owners()
  local keys, cmds = {}, {}
  for name, plugin in pairs(lazy_plugins()) do
    local handlers = plugin._ and plugin._.handlers or {}
    for _, k in pairs(handlers.keys or {}) do
      local modes = type(k.mode) == "table" and k.mode or { k.mode or "n" }
      for _, m in ipairs(modes) do
        local expanded = (m == "" and { "n", "x", "o" }) or (m == "v" and { "x", "s" }) or { m }
        for _, em in ipairs(expanded) do
          keys[em .. "|" .. normalize_lhs(k.lhs)] = name
        end
      end
    end
    for cmd in pairs(handlers.cmd or {}) do
      cmds[cmd] = name
    end
  end
  return keys, cmds
end

-- 1回の収集の間だけ使う手がかりをまとめて作る
local function make_resolver()
  local headings = keymaps_headings()
  local spec_files = plugin_spec_files()
  local lazy_keys, lazy_cmds = lazy_owners()
  local runtime = vim.fn.resolve(vim.env.VIMRUNTIME or "")

  local function from_plugin(name)
    local stem = spec_files[name]
    if stem then
      return { rank = RANK_CONFIG, order = stem, label = stem .. "  (plugins/" .. stem .. ".lua)" }
    end
    return { rank = RANK_PLUGIN, order = name, label = name .. "  (プラグイン)" }
  end

  local function from_file(src, line)
    if not src then
      return nil
    end
    src = vim.fn.resolve(src)
    if src == KEYMAPS_FILE then
      local title, order = "基本", 0
      for _, h in ipairs(headings) do
        if line and h.line <= line then
          title, order = h.title, h.line
        end
      end
      return { rank = RANK_KEYMAPS, order = order, label = title .. "  (keymaps.lua)" }
    end
    if src:sub(1, #CONFIG_DIR + 1) == CONFIG_DIR .. "/" then
      local rel = src:sub(#CONFIG_DIR + 2):gsub("^lua/", "")
      local stem = vim.fn.fnamemodify(rel, ":t:r")
      return { rank = RANK_CONFIG, order = stem, label = stem .. "  (" .. rel .. ")" }
    end
    if src:find("/lazy/lazy.nvim/", 1, true) then
      return nil -- lazy.nvim 自身の処理（keys の仮登録など）。持ち主は別途引く
    end
    local plugin = src:match("/lazy/([^/]+)/")
    if plugin then
      return from_plugin(plugin)
    end
    if runtime ~= "" and src:sub(1, #runtime) == runtime then
      return { rank = RANK_BUILTIN, order = "", label = "Neovim 標準" }
    end
    return nil
  end

  local builtin = { rank = RANK_BUILTIN, order = "", label = "Neovim 標準" }

  local resolver = {}

  function resolver.keymap(km, mode)
    local scope = km.buffer == 1 and "b" or "g"
    local lhs = keytrans(km.lhs)
    local rec = origins.keymaps[scope .. "|" .. mode .. "|" .. lhs]
    local group = rec and from_file(rec.src, rec.line)
    if not group and lazy_keys[mode .. "|" .. lhs] then
      group = from_plugin(lazy_keys[mode .. "|" .. lhs])
    end
    if not group and rec and rec.src:find("/lazy/lazy.nvim/", 1, true) then
      group = from_plugin("lazy.nvim")
    end
    if not group and km.callback then
      local info = debug.getinfo(km.callback, "S")
      if info.source:sub(1, 1) == "@" then
        group = from_file(info.source:sub(2), info.linedefined)
      end
    end
    if not group and km.sid and km.sid > 0 then
      local ok, si = pcall(vim.fn.getscriptinfo, { sid = km.sid })
      if ok and si[1] and not si[1].name:match("%.lua$") then
        group = from_file(si[1].name)
      end
    end
    return group or builtin
  end

  function resolver.command(name, c)
    local rec = origins.cmds[name]
    local group = rec and from_file(rec.src, rec.line)
    if not group and lazy_cmds[name] then
      group = from_plugin(lazy_cmds[name])
    end
    if not group and rec and rec.src:find("/lazy/lazy.nvim/", 1, true) then
      group = from_plugin("lazy.nvim")
    end
    if not group then
      local owner = plugin_by_module(unescape(c.definition or ""))
      group = owner and from_plugin(owner)
    end
    if not group and c.script_id and c.script_id > 0 then
      local ok, si = pcall(vim.fn.getscriptinfo, { sid = c.script_id })
      if ok and si[1] and not si[1].name:match("%.lua$") then
        group = from_file(si[1].name)
      end
    end
    return group or builtin
  end

  return resolver
end

-- 分類の並び替え用。group = { rank, order, label }
local function group_less(a, b)
  if a.rank ~= b.rank then
    return a.rank < b.rank
  end
  if a.order ~= b.order then
    if type(a.order) == type(b.order) then
      return a.order < b.order
    end
    return type(a.order) == "number"
  end
  return a.label < b.label
end

-- ==========================================
-- 各タブのデータ
-- ==========================================

local MODE_TAG = { n = "", x = " (v)", i = " (i)", t = " (t)" }
local MODE_ORDER = { n = 1, x = 2, i = 3, t = 4 }

-- 登録済みキーマップを、定義元ごとにまとめて集める
--   * desc が付いているものはすべて
--   * desc が無くても、自分の設定ファイルで定義したものは表示する（説明は rhs）
local function collect_keymaps(bufnr)
  local resolver = make_resolver()
  local items = {}
  for _, m in ipairs(MODES) do
    local seen = {}
    -- バッファローカルを優先して、同じ lhs のグローバルは隠す
    local ok, buf_maps = pcall(vim.api.nvim_buf_get_keymap, bufnr, m.mode)
    for _, src in ipairs({ ok and buf_maps or {}, vim.api.nvim_get_keymap(m.mode) }) do
      for _, km in ipairs(src) do
        if not km.lhs:match("^<Plug>") and not seen[km.lhs] then
          seen[km.lhs] = true
          local group = resolver.keymap(km, m.mode)
          local desc = km.desc and km.desc ~= "" and unescape(km.desc) or nil
          if not desc and group.rank <= RANK_CONFIG then
            desc = km.rhs and km.rhs ~= "" and ("→ " .. km.rhs) or "(説明なし)"
          end
          if desc then
            local lhs = km.lhs
            table.insert(items, {
              group = group,
              mode = m.mode,
              key = keytrans(lhs),
              desc = desc .. (km.buffer == 1 and "  [buffer]" or ""),
              -- ノーマルモードのキーマップだけその場で実行できる
              run = m.mode == "n" and function()
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "m", false)
              end or nil,
            })
          end
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.group.label ~= b.group.label then
      return group_less(a.group, b.group)
    end
    if a.mode ~= b.mode then
      return MODE_ORDER[a.mode] < MODE_ORDER[b.mode]
    end
    return a.key:lower() < b.key:lower()
  end)

  local entries = {}
  for _, it in ipairs(items) do
    table.insert(entries, {
      section = it.group.label,
      key = it.key .. MODE_TAG[it.mode],
      desc = it.desc,
      run = it.run,
    })
  end
  return entries
end

-- ユーザー定義コマンドを、定義元ごとにまとめて集める
local function collect_commands(bufnr)
  local resolver = make_resolver()
  local cmds = vim.tbl_extend(
    "force",
    vim.api.nvim_get_commands({ builtin = false }),
    vim.api.nvim_buf_get_commands(bufnr, {})
  )

  local items = {}
  for name, c in pairs(cmds) do
    local desc = vim.trim((unescape(c.definition or ""):gsub("\n.*", "")))
    if desc == "" then
      desc = "(説明なし)"
    end
    if c.nargs and c.nargs ~= "0" then
      desc = desc .. "  [引数: " .. c.nargs .. "]"
    end
    table.insert(items, { group = resolver.command(name, c), name = name, desc = desc })
  end
  table.sort(items, function(a, b)
    if a.group.label ~= b.group.label then
      return group_less(a.group, b.group)
    end
    return a.name:lower() < b.name:lower()
  end)

  local entries = {}
  for _, it in ipairs(items) do
    local name = it.name
    table.insert(entries, {
      section = it.group.label,
      key = ":" .. name,
      desc = it.desc,
      -- 引数を付けたいこともあるので、実行はせずコマンドラインに入れるだけ
      run = function()
        vim.api.nvim_feedkeys(":" .. name .. " ", "n", false)
      end,
    })
  end
  return entries
end

-- LuaSnip に登録されているスニペットを filetype ごとに集める
local function collect_snippets()
  local entries = {}
  local ok, ls = pcall(require, "luasnip")
  if not ok then
    table.insert(entries, { section = "スニペット", desc = "LuaSnip が読み込めません" })
    return entries
  end
  local by_ft = ls.get_snippets() or {}
  local fts = vim.tbl_keys(by_ft)
  table.sort(fts)
  for _, ft in ipairs(fts) do
    for _, snip in ipairs(by_ft[ft]) do
      local dscr = snip.dscr
      if type(dscr) == "table" then
        dscr = dscr[1]
      end
      table.insert(entries, {
        section = ft,
        key = snip.trigger,
        desc = (dscr and dscr ~= "" and dscr) or snip.name or "",
      })
    end
  end
  return entries
end

local function collect(key, bufnr)
  if key == "memo" then
    return collect_memo()
  elseif key == "keymaps" then
    return collect_keymaps(bufnr)
  elseif key == "snips" then
    return collect_snippets()
  else
    return collect_commands(bufnr)
  end
end

-- ==========================================
-- 描画
-- ==========================================

local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w >= width then
    return s .. " "
  end
  return s .. string.rep(" ", width - w)
end

-- タブの中身を行に変換する。
-- 戻り値: lines, highlights({ row, col_start, col_end, group }), actions(row -> entry)
local function build_lines(tab_idx, bufnr)
  local lines, hls, actions = {}, {}, {}

  -- タブバー
  local bar = " "
  for i, t in ipairs(TABS) do
    local label = string.format(" %d %s ", i, t.label)
    table.insert(hls, { 0, #bar, #bar + #label, i == tab_idx and "TabLineSel" or "TabLine" })
    bar = bar .. label .. " "
  end
  table.insert(lines, bar)
  table.insert(lines, "")

  local entries = collect(TABS[tab_idx].key, bufnr)
  local current = nil
  for _, e in ipairs(entries) do
    if e.section ~= current then
      current = e.section
      if #lines > 2 then
        table.insert(lines, "")
      end
      table.insert(lines, " ■ " .. e.section)
      table.insert(hls, { #lines - 1, 0, -1, "Title" })
    end

    if e.subheading then
      table.insert(lines, "   # " .. e.subheading)
      table.insert(hls, { #lines - 1, 0, -1, "Statement" })
    elseif e.key then
      local prefix = "   " .. pad(e.key, KEY_WIDTH)
      table.insert(lines, prefix .. e.desc)
      table.insert(hls, { #lines - 1, 3, #prefix, "Special" })
      actions[#lines] = e
    else
      table.insert(lines, "   " .. e.desc)
      table.insert(hls, { #lines - 1, 0, -1, "Comment" })
    end
  end

  if #entries == 0 then
    table.insert(lines, "   (項目がありません)")
  end
  return lines, hls, actions
end

local FOOTER = " <Tab>/1-4 タブ切替  / 検索  <CR> 実行  e 備忘録を編集  q 閉じる "

local function render()
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local lines, hls, actions = build_lines(state.tab, state.origin_buf)
  state.actions = actions

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local row, s, e, group = h[1], h[2], h[3], h[4]
    vim.api.nvim_buf_set_extmark(state.buf, ns, row, s, {
      end_row = e == -1 and row + 1 or row,
      end_col = e == -1 and 0 or e,
      hl_group = group,
      strict = false,
    })
  end

  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_cursor(state.win, { math.min(3, #lines), 0 })
  end
end

-- ==========================================
-- 横断検索（Telescope）
-- ==========================================

function M.search(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("[Cheatsheet] telescope.nvim が見つかりません", vim.log.levels.WARN)
    return
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local items = {}
  for _, t in ipairs(TABS) do
    for _, e in ipairs(collect(t.key, bufnr)) do
      if not e.subheading then
        e.tab = t.label
        table.insert(items, e)
      end
    end
  end

  local displayer = entry_display.create({
    separator = " ",
    items = { { width = 10 }, { width = KEY_WIDTH }, { remaining = true } },
  })

  pickers.new({}, {
    prompt_title = "コマンド集を検索",
    finder = finders.new_table({
      results = items,
      entry_maker = function(e)
        return {
          value = e,
          ordinal = table.concat({ e.tab, e.section, e.sub or "", e.key or "", e.desc }, " "),
          display = function()
            return displayer({
              { e.tab, "TelescopeResultsComment" },
              { e.key or "", "TelescopeResultsIdentifier" },
              e.desc .. "  (" .. e.section .. ")",
            })
          end,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel and sel.value.run then
          vim.schedule(sel.value.run)
        end
      end)
      return true
    end,
  }):find()
end

-- ==========================================
-- ウィンドウ操作
-- ==========================================

function M.close()
  if state and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state = nil
end

local function switch_tab(idx)
  state.tab = ((idx - 1) % #TABS) + 1
  render()
end

-- 閉じて元のウィンドウに戻ってから fn を実行する
local function close_then(fn)
  local origin = state.origin_win
  M.close()
  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  vim.schedule(fn)
end

function M.open(tab)
  if state then
    M.close()
  end

  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "cheatsheet"

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " コマンド集 ",
    title_pos = "center",
    footer = FOOTER,
    footer_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  state = { buf = buf, win = win, tab = 1, origin_win = origin_win, origin_buf = origin_buf }
  for i, t in ipairs(TABS) do
    if t.key == tab then
      state.tab = i
    end
  end
  render()

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("<Tab>", function() switch_tab(state.tab + 1) end)
  map("<S-Tab>", function() switch_tab(state.tab - 1) end)
  for i = 1, #TABS do
    map(tostring(i), function() switch_tab(i) end)
  end
  map("/", function()
    close_then(function() M.search(origin_buf) end)
  end)
  map("e", function()
    close_then(function() vim.cmd("edit " .. vim.fn.fnameescape(KEYS_FILE)) end)
  end)
  map("<CR>", function()
    local e = state.actions[vim.api.nvim_win_get_cursor(win)[1]]
    if e and e.run then
      close_then(e.run)
    end
  end)

  -- フォーカスが外れたら閉じる（Telescope へ移ったときなど）
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if state and state.win == win then
          M.close()
        end
      end)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("Cheatsheet", function(opts)
    local arg = opts.args
    if arg == "search" then
      M.search()
    else
      M.open(arg ~= "" and arg or nil)
    end
  end, {
    nargs = "?",
    complete = function() return { "search", "memo", "keymaps", "cmds", "snips" } end,
    desc = "コマンド集を表示（search / memo / keymaps / cmds / snips）",
  })
end

return M
