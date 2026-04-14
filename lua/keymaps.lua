-- キーマップ設定
local keymap = vim.keymap

-- リーダーキー（各種操作の起点）をスペースに設定
vim.g.mapleader = " "

-- aa でコメントトグル（VSCode の Command + / 相当、プラグインなし）
local function get_comment_prefix()
  local cs = vim.bo.commentstring
  if not cs or cs == "" then
    local ft = vim.bo.filetype
    if ft == "lua" or ft == "python" or ft == "sh" or ft == "yaml" or ft == "vim" or ft == "terraform" then
      cs = "# %s"
    else

      cs = "// %s"
    end
  end
  -- commentstring の %s より前をプレフィックスにする（例: "// %s" -> "// ", "# %s" -> "# "）
  local prefix = cs:match("^(.+)%%s") or "// "
  prefix = prefix:gsub("%s*$", "")
  if prefix ~= "" and not prefix:match("%s$") then
    prefix = prefix .. " "
  end
  return prefix
end

local function toggle_comment_line(line, prefix)
  local trimmed = line:match("^%s*(.*)%s*$") or line
  local indent = line:match("^(%s*)") or ""
  if trimmed:find("^" .. vim.pesc(prefix)) then
    return indent .. trimmed:gsub("^" .. vim.pesc(prefix), "", 1)
  else
    return indent .. prefix .. trimmed
  end
end

local function toggle_comment()
  local prefix = get_comment_prefix()
  local start_lnum = vim.api.nvim_buf_get_mark(0, "<")[1]
  local end_lnum = vim.api.nvim_buf_get_mark(0, ">")[1]
  if start_lnum == 0 then
    start_lnum = vim.fn.line(".")
    end_lnum = start_lnum
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_lnum - 1, end_lnum, false)
  local new_lines = {}
  for _, line in ipairs(lines) do
    table.insert(new_lines, toggle_comment_line(line, prefix))
  end
  vim.api.nvim_buf_set_lines(0, start_lnum - 1, end_lnum, false, new_lines)
  vim.api.nvim_buf_set_mark(0, "<", start_lnum, 1, {})
  vim.api.nvim_buf_set_mark(0, ">", end_lnum, 1, {})
end

keymap.set("n", "aa", function()
  vim.api.nvim_buf_set_mark(0, "<", vim.fn.line("."), 1, {})
  vim.api.nvim_buf_set_mark(0, ">", vim.fn.line("."), 1, {})
  toggle_comment()
end, { desc = "Toggle comment (current line)" })
keymap.set("v", "aa", toggle_comment, { desc = "Toggle comment (selection)" })

-- ビジュアル選択を指定文字で囲む（Space + w のあと 1 キー、行ジャンプと競合しない）
local function wrap_visual(left, right)
  right = right or left
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_lnum, start_col = start_pos[2], start_pos[3]
  local end_lnum, end_col = end_pos[2], end_pos[3]
  if start_lnum > end_lnum or (start_lnum == end_lnum and start_col > end_col) then
    start_lnum, end_lnum = end_lnum, start_lnum
    start_col, end_col = end_col, start_col
  end
  -- nvim_buf_get_text は 0-indexed、end は exclusive
  local lines = vim.api.nvim_buf_get_text(0, start_lnum - 1, start_col - 1, end_lnum - 1, end_col, {})
  local text = table.concat(lines, "\n")
  local replacement = left .. text .. right
  local new_lines = vim.split(replacement, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, start_lnum - 1, start_col - 1, end_lnum - 1, end_col, new_lines)
  vim.api.nvim_input("<Esc>")
end

-- 囲む: Space+w のあと英字1つ（行ジャンプの {}[]() と競合しない）
keymap.set("v", "<leader>w\"", function() wrap_visual('"', '"') end, { desc = "Wrap with \"\"" })
keymap.set("v", "<leader>w'", function() wrap_visual("'", "'") end, { desc = "Wrap with ''" })
keymap.set("v", "<leader>wb", function() wrap_visual("{", "}") end, { desc = "Wrap with {} (b=brace)" })
keymap.set("v", "<leader>wp", function() wrap_visual("(", ")") end, { desc = "Wrap with () (p=paren)" })
keymap.set("v", "<leader>ws", function() wrap_visual("[", "]") end, { desc = "Wrap with [] (s=square)" })
keymap.set("v", "<leader>w`", function() wrap_visual("`", "`") end, { desc = "Wrap with ``" })

-- Insert モード: qw で現在の単語を選択（続けて ( や { で囲める）。q のみのときは 500ms でタイムアウトして "q" を挿入
keymap.set("i", "q", function()
  local c = vim.fn.getchar(500)
  if c == 0 or c == nil then
    vim.api.nvim_feedkeys("q", "n", true)
  elseif c == 119 or c == string.byte("w") then
    vim.api.nvim_feedkeys("<Esc>viw", "n", false)
  else
    vim.api.nvim_feedkeys("q" .. (type(c) == "number" and vim.fn.nr2char(c) or tostring(c)), "n", true)
  end
end, { desc = "q then w: select word (then type ( or { to wrap)" })

-- ビジュアルモード: ( や { などで選択範囲を囲む（Insert で qw のあとに押す想定）
keymap.set("v", "(", function() wrap_visual("(", ")") end, { desc = "Wrap selection with ()" })
keymap.set("v", "{", function() wrap_visual("{", "}") end, { desc = "Wrap selection with {}" })
keymap.set("v", "[", function() wrap_visual("[", "]") end, { desc = "Wrap selection with []" })

-- Option + ↓/↑ で選択行を下/上に移動（VSCode と同じ、プラグインなし）
-- 複数行: V でビジュアル行選択 → j/k で範囲指定 → <A-Up>/<A-Down>
local function get_line_range()
  local start_lnum = vim.api.nvim_buf_get_mark(0, "<")[1]
  local end_lnum = vim.api.nvim_buf_get_mark(0, ">")[1]
  if start_lnum == 0 then
    start_lnum = vim.fn.line(".")
    end_lnum = start_lnum
  end
  if start_lnum > end_lnum then
    start_lnum, end_lnum = end_lnum, start_lnum
  end
  return start_lnum, end_lnum
end

local function move_lines_down()
  local start_lnum, end_lnum = get_line_range()
  local last_line = vim.fn.line("$")
  if end_lnum >= last_line then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_lnum - 1, end_lnum, false)
  vim.api.nvim_buf_set_lines(0, start_lnum - 1, end_lnum, false, {})
  local insert_at = end_lnum
  vim.api.nvim_buf_set_lines(0, insert_at, insert_at, false, lines)
  vim.api.nvim_buf_set_mark(0, "<", end_lnum + 1, 1, {})
  vim.api.nvim_buf_set_mark(0, ">", end_lnum + #lines, 1, {})
  vim.fn.cursor(end_lnum + 1, 1)
  if vim.fn.mode() == "V" or vim.fn.mode() == "v" then
    vim.cmd("normal! '<V'>")
  end
end

local function move_lines_up()
  local start_lnum, end_lnum = get_line_range()
  if start_lnum <= 1 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_lnum - 1, end_lnum, false)
  vim.api.nvim_buf_set_lines(0, start_lnum - 1, end_lnum, false, {})
  local insert_at = start_lnum - 2
  vim.api.nvim_buf_set_lines(0, insert_at, insert_at, false, lines)
  vim.api.nvim_buf_set_mark(0, "<", start_lnum - 1, 1, {})
  vim.api.nvim_buf_set_mark(0, ">", start_lnum - 2 + #lines, 1, {})
  vim.fn.cursor(start_lnum - 1, 1)
  if vim.fn.mode() == "V" or vim.fn.mode() == "v" then
    vim.cmd("normal! '<V'>")
  end
end

keymap.set("n", "<A-Down>", function()
  vim.api.nvim_buf_set_mark(0, "<", vim.fn.line("."), 1, {})
  vim.api.nvim_buf_set_mark(0, ">", vim.fn.line("."), 1, {})
  move_lines_down()
end, { desc = "Move line(s) down" })
keymap.set("n", "<A-Up>", function()
  vim.api.nvim_buf_set_mark(0, "<", vim.fn.line("."), 1, {})
  vim.api.nvim_buf_set_mark(0, ">", vim.fn.line("."), 1, {})
  move_lines_up()
end, { desc = "Move line(s) up" })
keymap.set("v", "<A-Down>", ":move '>+1<CR>gv", { noremap = true, silent = true, desc = "Move selection down" })
keymap.set("v", "<A-Up>", ":move '<-2<CR>gv", { noremap = true, silent = true, desc = "Move selection up" })
-- 挿入モード: 現在行を1行だけ移動して挿入モードに戻る
keymap.set("i", "<A-Down>", function()
  vim.cmd("normal! <Esc>")
  vim.api.nvim_buf_set_mark(0, "<", vim.fn.line("."), 1, {})
  vim.api.nvim_buf_set_mark(0, ">", vim.fn.line("."), 1, {})
  move_lines_down()
  vim.cmd("startinsert")
end, { desc = "Move line down (insert mode)" })
keymap.set("i", "<A-Up>", function()
  vim.cmd("normal! <Esc>")
  vim.api.nvim_buf_set_mark(0, "<", vim.fn.line("."), 1, {})
  vim.api.nvim_buf_set_mark(0, ">", vim.fn.line("."), 1, {})
  move_lines_up()
  vim.cmd("startinsert")
end, { desc = "Move line up (insert mode)" })

-- jk でインサートモードを抜ける
keymap.set("i", "jk", "<Esc>", { desc = "Exit insert mode" })

-- スペース + nh で検索のハイライトを消す
keymap.set("n", "<leader>nh", ":nohlsearch<CR>", { desc = "Clear search highlights" })

-- Esc で検索のハイライトを消す（検索文字が残るのを防ぐ）
keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR><Esc>", { desc = "Clear search highlights" })

-- Command + f でファイル内検索を開始（macOS）
keymap.set("n", "<D-f>", function()
    require("telescope.builtin").current_buffer_fuzzy_find({
        previewer = false,
    })
end, { desc = "Search in current file" })
keymap.set("v", "<D-f>", function()
    require("telescope.builtin").current_buffer_fuzzy_find({
        previewer = false,
    })
end, { desc = "Search in current file" })
keymap.set("i", "<D-f>", function()
    vim.cmd("stopinsert")
    require("telescope.builtin").current_buffer_fuzzy_find({
        previewer = false,
    })
end, { desc = "Search in current file" })

-- 検索結果の次/前へ移動しつつ中央に表示
keymap.set("n", "n", "nzzzv", { noremap = true, silent = true })
keymap.set("n", "N", "Nzzzv", { noremap = true, silent = true })

-- エンター2回で検索プロンプトを表示（検索文字列が見やすく表示される）
local enter_timer = nil
keymap.set("n", "<CR>", function()
  if enter_timer then
    -- 2回目のエンター：検索プロンプトを表示
    vim.fn.timer_stop(enter_timer)
    enter_timer = nil

    -- ノーマルモードに確実に戻す
    if vim.fn.mode() ~= "n" then
      vim.cmd("normal! <Esc>")
    end

    -- 検索ハイライトを有効にする
    vim.opt.hlsearch = true

    -- 検索プロンプトを表示（コマンドラインで検索を開始）
    vim.schedule(function()
      vim.fn.feedkeys("/", "t")
    end)
  else
    -- 1回目のエンター：タイマーを開始
    enter_timer = vim.fn.timer_start(500, function()
      enter_timer = nil
      vim.schedule(function()
        vim.cmd("normal! <CR>")
      end)
    end)
  end
end, { noremap = true, desc = "Enter twice to search" })

-- 画面分割
keymap.set("n", "<leader>sv", "<C-w>v", { desc = "Split window vertically" })
keymap.set("n", "<leader>sh", "<C-w>s", { desc = "Split window horizontally" })

-- タブ操作
keymap.set("n", "te", ":tabedit", { desc = "新しいタブを開く" }) -- tab edit
keymap.set("n", "gn", ":tabnext<Return>", { desc = "次のタブへ" }) -- go next
keymap.set("n", "gp", ":tabprev<Return>", { desc = "前のタブへ" }) -- go previous
keymap.set("n", "tx", function()
    if vim.fn.tabpagenr('$') > 1 then
        vim.cmd('tabclose')
    end
end, { desc = "タブを閉じる" }) -- tab closie

-- nvim-tree
-- スペース + e でツリーを開閉する (e は Explorer の e)
keymap.set("n", "<leader>e", ":NvimTreeToggle<Return>", { desc = "Toggle file explorer" })

-- 全選択 (Command + a)
keymap.set("n", "<C-a>", "ggVG", { desc = "Select all" })

-- Command + a を全選択にする設定（環境によって動作しない場合があります）
keymap.set("n", "<D-a>", "ggVG", { desc = "Select all" })
keymap.set("v", "<D-a>", "<Esc>ggVG", { desc = "Select all" })
keymap.set("i", "<D-a>", "<Esc>ggVG", { desc = "Select all" })

-- スペース + ya で全コピー
keymap.set("n", "<leader>ya", ":%y<CR>", { desc = "Copy all" })

-- インサートモード中に Command + z (または Ctrl + z) で元に戻す
-- MacのCommandキーを利用する場合
keymap.set("i", "<D-z>", "<Esc>ui", { desc = "Undo in insert mode" })
-- もしCommandが効かない場合は Ctrl + z も設定しておくと安心です
keymap.set("i", "<C-z>", "<Esc>ui", { desc = "Undo in insert mode" })

-- ノーマルモードの Command + z もついでに設定
keymap.set("n", "<D-z>", "u", { desc = "Undo" })

-- 前のファイル（ジャンプ）へ
keymap.set("n", "<A-Left>", "<C-o>", { noremap = true, silent = true })
keymap.set("n", "\x1bb", "<C-o>", { noremap = true, silent = true })

-- 次のファイル（ジャンプ）へ
keymap.set("n", "<A-Right>", "<C-i>", { noremap = true, silent = true })
keymap.set("n", "\x1bf", "<C-i>", { noremap = true, silent = true })

-- タブを開く → ⌘T
keymap.set("n", "<D-t>", ":tabedit<CR>", { desc = "新しいタブを開く" })

-- gd → 定義ジャンプ
keymap.set("n", "gd", function()
    local clients = vim.lsp.get_clients({ bufnr = 0 })
    for _, client in ipairs(clients) do
        if client.server_capabilities.definitionProvider then
            vim.lsp.buf.definition({ reuse_win = true })
            return
        end
    end
    vim.notify("定義ジャンプに対応したLSPがありません", vim.log.levels.WARN)
end, { desc = "Go to definition" })

-- ==========================================
-- Git 操作
-- ==========================================

-- スペース + g で Lazygit を起動
keymap.set("n", "<leader>g", ":LazyGit<CR>", { desc = "Lazygitを起動 (Git操作)" })

-- diffview: 差分ビュー（checktime で外部変更を再読み込みしてから表示）
keymap.set("n", "<leader>df", "<cmd>checktime<CR><cmd>DiffviewOpen<CR>", { desc = "差分ビューを開く" })
keymap.set("n", "<leader>dfh", "<cmd>checktime<CR><cmd>DiffviewFileHistory %<CR>", { desc = "ファイルの変更履歴" })
keymap.set("n", "<leader>dfH", "<cmd>checktime<CR><cmd>DiffviewFileHistory<CR>", { desc = "リポジトリの変更履歴" })
keymap.set("n", "<leader>dfc", "<cmd>DiffviewClose<CR>", { desc = "差分ビューを閉じる" })
keymap.set("n", "<leader>dfr", "<cmd>DiffviewRefresh<CR>", { desc = "差分ビューをリフレッシュ" })

-- gitsigns: hunk間の移動
keymap.set("n", "]c", function()
  if vim.wo.diff then return "]c" end
  vim.schedule(function() require("gitsigns").next_hunk() end)
  return "<Ignore>"
end, { expr = true, desc = "次の変更箇所へ" })

keymap.set("n", "[c", function()
  if vim.wo.diff then return "[c" end
  vim.schedule(function() require("gitsigns").prev_hunk() end)
  return "<Ignore>"
end, { expr = true, desc = "前の変更箇所へ" })

-- gitsigns: hunk操作
keymap.set("n", "<leader>hp", function() require("gitsigns").preview_hunk() end, { desc = "変更をプレビュー" })
keymap.set("n", "<leader>hs", function() require("gitsigns").stage_hunk() end, { desc = "変更をステージ" })
keymap.set("n", "<leader>hr", function() require("gitsigns").reset_hunk() end, { desc = "変更をリセット" })
keymap.set("v", "<leader>hs", function() require("gitsigns").stage_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, { desc = "選択範囲をステージ" })
keymap.set("v", "<leader>hr", function() require("gitsigns").reset_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, { desc = "選択範囲をリセット" })
keymap.set("n", "<leader>hu", function() require("gitsigns").undo_stage_hunk() end, { desc = "ステージを取り消し" })
keymap.set("n", "<leader>hS", function() require("gitsigns").stage_buffer() end, { desc = "ファイル全体をステージ" })
keymap.set("n", "<leader>hR", function() require("gitsigns").reset_buffer() end, { desc = "ファイル全体をリセット" })

-- gitsigns: 差分表示
keymap.set("n", "<leader>hd", function() require("gitsigns").diffthis() end, { desc = "差分を表示 (index)" })
keymap.set("n", "<leader>hD", function() require("gitsigns").diffthis("~") end, { desc = "差分を表示 (前回commit)" })

-- gitsigns: blame
keymap.set("n", "<leader>hb", function() require("gitsigns").blame_line({ full = true }) end, { desc = "行のblame詳細" })
keymap.set("n", "<leader>hB", function() require("gitsigns").toggle_current_line_blame() end, { desc = "blame表示の切替" })

-- gitsigns: 削除行の表示
keymap.set("n", "<leader>hl", function() require("gitsigns").toggle_deleted() end, { desc = "削除行の表示切替" })

-- スペース + p (Project) でプロジェクト一覧を表示
-- 選択するとそのディレクトリに移動(cd)してファイル検索が開きます
keymap.set('n', '<leader>p', function()
    require('telescope').load_extension('projects')
    require('telescope').extensions.projects.projects({})
end, { desc = "プロジェクトを切り替える" })

-- スペース + s + f で拡張子を指定してファイル検索（前回の拡張子を保持）
vim.g.telescope_ext_filter = vim.g.telescope_ext_filter or '*'
local function get_project_root()
    local bufpath = vim.api.nvim_buf_get_name(0)
    local bufdir = bufpath ~= "" and vim.fn.fnamemodify(bufpath, ":h") or vim.fn.getcwd()
    local git_root = vim.fn.systemlist("cd " .. vim.fn.shellescape(bufdir) .. " && git rev-parse --show-toplevel")[1]
    if vim.v.shell_error == 0 and git_root and git_root ~= "" then
        return git_root
    end
    return vim.fn.getcwd()
end

local function find_files_with_extension()
    vim.ui.input({ prompt = '拡張子 (例: php, tsx, *): ', default = vim.g.telescope_ext_filter }, function(ext)
        if not ext or ext == '' then
            return
        end
        vim.g.telescope_ext_filter = ext

        local cmd = { 'rg', '--files' }
        if ext ~= '*' then
            for e in string.gmatch(ext, '([^,%s]+)') do
                table.insert(cmd, '--glob')
                table.insert(cmd, string.format('*.%s', e))
            end
        end
        require('telescope.builtin').find_files({ find_command = cmd, cwd = get_project_root() })
    end)
end

keymap.set('n', '<leader>sf', find_files_with_extension, { desc = "拡張子を指定して検索" })

local function live_grep_with_extension()
    vim.ui.input({ prompt = '拡張子 (例: lua  !json  tsx,jsx  !*.min.js): ', default = vim.g.telescope_grep_ext_filter }, function(ext)
        if not ext or ext == '' then
            return
        end
        vim.g.telescope_grep_ext_filter = ext

        local globs = {}
        for e in string.gmatch(ext, '([^,%s]+)') do
            if e:match('^!') then
                local pattern = e:sub(2)
                if not pattern:match('%*') then
                    pattern = '*.' .. pattern
                end
                table.insert(globs, '!' .. pattern)
            else
                if not e:match('%*') then
                    e = '*.' .. e
                end
                table.insert(globs, e)
            end
        end

        require('telescope.builtin').live_grep({
            glob_pattern = globs,
            cwd = get_project_root(),
        })
    end)
end

keymap.set('n', '<leader>sz', live_grep_with_extension, { desc = "拡張子を指定して全文検索" })

-- keymaps.lua に入っている設定
keymap.set("i", "<D-z>", "<Esc>ui", { desc = "挿入モードで元に戻す" })
keymap.set("i", "<C-z>", "<Esc>ui", { desc = "挿入モードで元に戻す" })


-- ALT + n: 次のタブへ移動（WezTermのウィンドウ切り替えに対応）
keymap.set("n", "<A-n>", ":tabnext<CR>", { desc = "次のタブへ（WezTerm互換）" })

-- ALT + SHIFT + RightArrow: 垂直分割（左右分割）
keymap.set("n", "<A-S-Right>", "<C-w>v", { desc = "垂直分割（WezTerm互換）" })

-- ALT + SHIFT + DownArrow: 水平分割（上下分割）
keymap.set("n", "<A-S-Down>", "<C-w>s", { desc = "水平分割（WezTerm互換）" })

-- ALT + CMD + 矢印キー: ペイン間を移動
keymap.set("n", "<A-D-Left>", "<C-w>h", { desc = "左のペインへ移動（WezTerm互換）" })
keymap.set("n", "<A-D-Right>", "<C-w>l", { desc = "右のペインへ移動（WezTerm互換）" })
keymap.set("n", "<A-D-Up>", "<C-w>k", { desc = "上のペインへ移動（WezTerm互換）" })
keymap.set("n", "<A-D-Down>", "<C-w>j", { desc = "下のペインへ移動（WezTerm互換）" })

-- ALT + x: 現在のペインを閉じる
keymap.set("n", "<A-x>", "<C-w>c", { desc = "ペインを閉じる（WezTerm互換）" })

-- T (Shift+t): フローティングターミナルの開閉は toggleterm.nvim で管理
-- （設定は lua/plugins/toggleterm.lua）

-- Option + Shift + F でコード整形
keymap.set({ "n", "v", "i" }, "<M-S-f>", function()
    require("conform").format({ async = true, lsp_fallback = false })
end, { desc = "Format code" })

-- 現在の行のエラーメッセージをクリップボードにコピーする設定
vim.keymap.set('n', '<leader>ce', function()
    local filepath = vim.fn.expand('%:p')
    if filepath == '' then
        print("No file path")
        return
    end

    -- 現在の行の診断情報を取得
    local line = vim.fn.line('.') - 1
    local diagnostics = vim.diagnostic.get(0, { lnum = line })

    local value = string.format('%s:%d', filepath, line + 1)
    if vim.tbl_isempty(diagnostics) then
        vim.fn.setreg('+', value)
        print("Copied file path and line number!")
        return
    end

    local message = diagnostics[1].message
    value = string.format('%s\n%s', value, message)
    vim.fn.setreg('+', value)
    print("Copied error message with file path and line number!")
end, { desc = "Copy diagnostic with file path and line" })

-- ==========================================
-- React Component Tree
-- ==========================================

-- スペース + rt: 現在ファイルのコンポーネントツリーを表示
keymap.set("n", "<leader>rt", function()
  require("react-tree").show()
end, { desc = "React: コンポーネントツリーを表示" })

-- スペース + rp: ルートコンポーネントを選択してツリー表示
keymap.set("n", "<leader>rp", function()
  require("react-tree").pick_root()
end, { desc = "React: ルートを選んでツリー表示" })

-- スペース + rd: デバッグ（treesitterがJSXノードを認識しているか確認）
keymap.set("n", "<leader>rd", function()
  require("react-tree").debug()
end, { desc = "React: ツリーデバッグ" })
