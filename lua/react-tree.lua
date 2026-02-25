-- React Component Tree Viewer
-- treesitterでJSX/TSXを解析し、コンポーネントの階層構造をツリー表示する
local M = {}

local EXTENSIONS = { ".tsx", ".ts", ".jsx", ".js" }

--- 相対importパスを実ファイルパスに解決
local function resolve_import(import_path, current_file)
  if not import_path:match("^%.") then
    return nil
  end

  local dir = vim.fn.fnamemodify(current_file, ":h")
  local base = vim.fn.resolve(dir .. "/" .. import_path)

  for _, ext in ipairs(EXTENSIONS) do
    local p = base .. ext
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end

  for _, ext in ipairs(EXTENSIONS) do
    local p = base .. "/index" .. ext
    if vim.fn.filereadable(p) == 1 then
      return p
    end
  end

  return nil
end

--- import文を解析してコンポーネント名 -> ファイルパスのマップを返す
local function parse_imports(content, filepath)
  local imports = {}

  for line in content:gmatch("[^\n]+") do
    -- import Default from './path'
    local def, path = line:match("import%s+([A-Z]%w*)%s+from%s+['\"]([^'\"]+)['\"]")
    if def then
      imports[def] = resolve_import(path, filepath)
    end

    -- import { Named, ... } from './path'
    local named, path2 = line:match("import%s*{([^}]+)}%s*from%s*['\"]([^'\"]+)['\"]")
    if named then
      local resolved = resolve_import(path2, filepath)
      for name in named:gmatch("([A-Z]%w*)") do
        imports[name] = resolved
      end
    end

    -- import Default, { Named } from './path'
    local d, n, p = line:match("import%s+([A-Z]%w*)%s*,%s*{([^}]+)}%s*from%s*['\"]([^'\"]+)['\"]")
    if d then
      local resolved = resolve_import(p, filepath)
      imports[d] = resolved
      for name in n:gmatch("([A-Z]%w*)") do
        imports[name] = resolved
      end
    end
  end

  return imports
end

--- treesitterのASTを走査してJSXコンポーネントのツリーを抽出
--- @param node TSNode
--- @param bufnr number バッファ番号（get_node_text用）
--- @param imports table コンポーネント名->ファイルパスのマップ
local function extract_jsx_tree(node, bufnr, imports)
  local result = {}

  for child in node:iter_children() do
    local ntype = child:type()

    if ntype == "jsx_self_closing_element" then
      local tag_name = nil
      for c in child:iter_children() do
        local ct = c:type()
        if ct == "identifier" or ct == "member_expression" then
          tag_name = vim.treesitter.get_node_text(c, bufnr)
          break
        end
      end
      if tag_name and tag_name:match("^[A-Z]") then
        table.insert(result, {
          name = tag_name,
          file = imports[tag_name:match("^([^.]+)")],
          children = {},
        })
      end

    elseif ntype == "jsx_element" then
      local tag_name = nil
      local jsx_children = {}

      for c in child:iter_children() do
        local ct = c:type()
        if ct == "jsx_opening_element" then
          for gc in c:iter_children() do
            local gct = gc:type()
            if gct == "identifier" or gct == "member_expression" then
              tag_name = vim.treesitter.get_node_text(gc, bufnr)
              break
            end
          end
        elseif ct ~= "jsx_closing_element" then
          local sub = extract_jsx_tree(c, bufnr, imports)
          vim.list_extend(jsx_children, sub)
        end
      end

      if tag_name and tag_name:match("^[A-Z]") then
        table.insert(result, {
          name = tag_name,
          file = imports[tag_name:match("^([^.]+)")],
          children = jsx_children,
        })
      else
        vim.list_extend(result, jsx_children)
      end
    else
      local sub = extract_jsx_tree(child, bufnr, imports)
      vim.list_extend(result, sub)
    end
  end

  return result
end

--- 拡張子からfiletypeを取得
local function get_filetype(filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  if ext == "tsx" then
    return "typescriptreact"
  elseif ext == "ts" then
    return "typescript"
  elseif ext == "jsx" then
    return "javascriptreact"
  end
  return "javascript"
end

--- ファイルからコンポーネント名を推定
local function find_component_name(content, filepath)
  for line in content:gmatch("[^\n]+") do
    local name = line:match("export%s+default%s+function%s+([A-Z]%w*)")
      or line:match("^function%s+([A-Z]%w*)")
      or line:match("export%s+const%s+([A-Z]%w*)%s*[=:]")
      or line:match("^const%s+([A-Z]%w*)%s*[=:]")
      or line:match("export%s+default%s+class%s+([A-Z]%w*)")
    if name then
      return name
    end
  end
  local basename = vim.fn.fnamemodify(filepath, ":t:r")
  if basename == "index" then
    basename = vim.fn.fnamemodify(filepath, ":h:t")
  end
  return basename
end

--- バッファベースでtreesitterパーサーを取得
local function parse_with_buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype

  -- 言語名を指定せず、filetypeから自動検出させる
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil, nil
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    return nil, nil
  end

  return trees[1]:root(), buf
end

--- ファイルを解析してコンポーネントツリーを返す
local function parse_file(filepath, depth, max_depth, visited)
  depth = depth or 0
  max_depth = max_depth or 6
  visited = visited or {}

  if depth > max_depth then
    return nil
  end

  local abs_path = vim.fn.resolve(filepath)
  if visited[abs_path] then
    return { name = "...", file = abs_path, circular = true, children = {} }
  end
  visited[abs_path] = true

  local ok_read, lines = pcall(vim.fn.readfile, filepath)
  if not ok_read or not lines or #lines == 0 then
    return nil
  end

  local content = table.concat(lines, "\n")
  local comp_name = find_component_name(content, filepath)
  local imports = parse_imports(content, filepath)
  local filetype = get_filetype(filepath)

  -- 現在のバッファか、一時バッファを使う
  local root_node, bufnr
  local current_buf_file = vim.fn.resolve(vim.fn.expand("%:p"))
  local should_delete = false

  if abs_path == current_buf_file then
    -- 現在開いているバッファをそのまま使う（言語名は自動検出）
    local ok_p, parser = pcall(vim.treesitter.get_parser, 0)
    if ok_p then
      local trees = parser:parse()
      if trees and #trees > 0 then
        root_node = trees[1]:root()
        bufnr = 0
      end
    end
  end

  -- 現在バッファでなければ一時バッファで解析
  if not root_node then
    root_node, bufnr = parse_with_buffer(lines, filetype)
    if bufnr and bufnr ~= 0 then
      should_delete = true
    end
  end

  if not root_node then
    return { name = comp_name, file = abs_path, children = {} }
  end

  local jsx_tree = extract_jsx_tree(root_node, bufnr, imports)

  -- 一時バッファを削除
  if should_delete and bufnr then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  -- 子コンポーネントのファイルを再帰的に解析
  local function resolve_deep(nodes)
    for _, node in ipairs(nodes) do
      if node.file and not node.circular and #node.children == 0 then
        local child_result = parse_file(node.file, depth + 1, max_depth, visited)
        if child_result and #child_result.children > 0 then
          node.children = child_result.children
        end
      end
      if #node.children > 0 then
        resolve_deep(node.children)
      end
    end
  end

  resolve_deep(jsx_tree)

  return {
    name = comp_name,
    file = abs_path,
    children = jsx_tree,
  }
end

--- ツリーを表示用の行に変換
local function render_tree(node, lines, highlights, nav_map, prefix, is_last, depth)
  lines = lines or {}
  highlights = highlights or {}
  nav_map = nav_map or {}
  prefix = prefix or ""
  depth = depth or 0

  local line_nr = #lines
  local connector = ""
  if depth > 0 then
    connector = is_last and "└── " or "├── "
  end

  local display = node.name
  if node.circular then
    display = display .. " (circular)"
  end

  local rel_path = ""
  if node.file then
    rel_path = "  " .. vim.fn.fnamemodify(node.file, ":~:.")
  end

  local line = prefix .. connector .. display .. rel_path
  table.insert(lines, line)

  local name_start = #prefix + #connector
  table.insert(highlights, {
    line = line_nr,
    name_col = name_start,
    name_end = name_start + #display,
    path_col = name_start + #display,
    path_end = #line,
    tree_end = name_start,
    depth = depth,
    circular = node.circular,
    has_children = #node.children > 0,
  })

  nav_map[line_nr + 1] = node.file

  local child_prefix = prefix
  if depth > 0 then
    child_prefix = prefix .. (is_last and "    " or "│   ")
  end

  for i, child in ipairs(node.children) do
    render_tree(child, lines, highlights, nav_map, child_prefix, i == #node.children, depth + 1)
  end

  return lines, highlights, nav_map
end

--- フローティングウィンドウを作成してツリーを表示
local function show_tree_window(tree, title)
  local lines, highlights, nav_map = render_tree(tree)

  if #lines == 0 then
    vim.notify("Component tree is empty", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "react-tree"

  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  local width = math.min(math.max(max_width + 4, 50), math.floor(vim.o.columns * 0.85))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.75))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  local ns = vim.api.nvim_create_namespace("react_tree")

  local depth_colors = {
    [0] = "DiagnosticOk",
    [1] = "Function",
    [2] = "Keyword",
    [3] = "Type",
    [4] = "String",
    [5] = "Number",
    [6] = "Constant",
  }

  for _, hl in ipairs(highlights) do
    if hl.tree_end > 0 then
      vim.api.nvim_buf_add_highlight(buf, ns, "NonText", hl.line, 0, hl.tree_end)
    end
    local name_hl = depth_colors[hl.depth] or "Identifier"
    if hl.circular then
      name_hl = "DiagnosticWarn"
    elseif hl.has_children then
      name_hl = depth_colors[hl.depth] or "Function"
    end
    vim.api.nvim_buf_add_highlight(buf, ns, name_hl, hl.line, hl.name_col, hl.name_end)
    if hl.path_col < hl.path_end then
      vim.api.nvim_buf_add_highlight(buf, ns, "Comment", hl.line, hl.path_col, hl.path_end)
    end
  end

  local bopts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, bopts)

  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, bopts)

  vim.keymap.set("n", "<CR>", function()
    local lnr = vim.fn.line(".")
    local file = nav_map[lnr]
    if file and vim.fn.filereadable(file) == 1 then
      vim.api.nvim_win_close(win, true)
      vim.cmd("edit " .. vim.fn.fnameescape(file))
    end
  end, bopts)

  vim.keymap.set("n", "o", function()
    local lnr = vim.fn.line(".")
    local file = nav_map[lnr]
    if file and vim.fn.filereadable(file) == 1 then
      vim.api.nvim_win_close(win, true)
      local sub_tree = parse_file(file, 0, 6, {})
      if sub_tree and #sub_tree.children > 0 then
        show_tree_window(sub_tree, " " .. sub_tree.name .. " ")
      else
        vim.notify("No child components found", vim.log.levels.INFO)
      end
    end
  end, bopts)
end

--- 現在のファイルのコンポーネントツリーを表示
function M.show()
  local filepath = vim.fn.expand("%:p")
  local ext = vim.fn.fnamemodify(filepath, ":e")

  if not vim.tbl_contains({ "tsx", "ts", "jsx", "js" }, ext) then
    vim.notify("React Component Tree: JSX/TSX file only", vim.log.levels.WARN)
    return
  end

  local tree = parse_file(filepath, 0, 6, {})
  if not tree then
    vim.notify("React Component Tree: parse failed", vim.log.levels.ERROR)
    return
  end

  if #tree.children == 0 then
    vim.notify("React Component Tree: no components found", vim.log.levels.INFO)
    return
  end

  show_tree_window(tree, " " .. tree.name .. " Component Tree ")
end

--- デバッグ: treesitterのASTを表示して問題を特定する
function M.debug()
  local filepath = vim.fn.expand("%:p")

  -- 言語名を指定せず自動検出
  local ok, parser = pcall(vim.treesitter.get_parser, 0)
  if not ok then
    vim.notify("Treesitter parser not available for this buffer. Try :TSInstall tsx", vim.log.levels.ERROR)
    return
  end
  local lang = parser:lang()

  local trees = parser:parse()
  if not trees or #trees == 0 then
    vim.notify("Treesitter parse returned no trees", vim.log.levels.ERROR)
    return
  end

  local root = trees[1]:root()

  -- JSX関連ノードを探す
  local jsx_nodes = {}
  local function find_jsx(node, depth)
    local ntype = node:type()
    if ntype:match("^jsx") then
      local text = vim.treesitter.get_node_text(node, 0)
      if #text > 80 then
        text = text:sub(1, 80) .. "..."
      end
      table.insert(jsx_nodes, string.rep("  ", depth) .. ntype .. ": " .. text:gsub("\n", " "))
    end
    for child in node:iter_children() do
      find_jsx(child, depth + 1)
    end
  end

  find_jsx(root, 0)

  if #jsx_nodes == 0 then
    vim.notify("No JSX nodes found in AST.\nLanguage: " .. lang .. "\nRoot type: " .. root:type(), vim.log.levels.WARN)
    return
  end

  -- 結果を表示
  local buf = vim.api.nvim_create_buf(false, true)
  table.insert(jsx_nodes, 1, "Language: " .. lang)
  table.insert(jsx_nodes, 2, "Root type: " .. root:type())
  table.insert(jsx_nodes, 3, "JSX nodes found: " .. (#jsx_nodes - 2))
  table.insert(jsx_nodes, 4, string.rep("-", 60))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, jsx_nodes)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"

  local width = math.min(100, math.floor(vim.o.columns * 0.85))
  local height = math.min(#jsx_nodes, math.floor(vim.o.lines * 0.75))

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " React Tree Debug ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf, silent = true })
end

--- 指定ディレクトリ配下の全コンポーネントをスキャンしてルート候補を表示
function M.pick_root()
  local ok, telescope = pcall(require, "telescope.builtin")
  if not ok then
    vim.notify("Telescope required for pick_root", vim.log.levels.ERROR)
    return
  end

  telescope.find_files({
    prompt_title = "Select Root Component",
    find_command = { "rg", "--files", "--glob", "*.tsx", "--glob", "*.jsx" },
    attach_mappings = function(_, map)
      map("i", "<CR>", function(prompt_bufnr)
        local action_state = require("telescope.actions.state")
        local entry = action_state.get_selected_entry()
        require("telescope.actions").close(prompt_bufnr)

        if entry then
          local file = entry.path or entry[1]
          local tree = parse_file(file, 0, 6, {})
          if tree and #tree.children > 0 then
            show_tree_window(tree, " " .. tree.name .. " Component Tree ")
          else
            vim.notify("No child components found in " .. file, vim.log.levels.INFO)
          end
        end
      end)
      return true
    end,
  })
end

return M
