return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    config = function()
      require("catppuccin").setup({
        flavour = "mocha",
        transparent_background = true,
      })
      vim.cmd("colorscheme catppuccin")

      -- TODO を見やすくする
      local todo_fg = "#ffd75f" -- bright yellow for dark background
      vim.api.nvim_set_hl(0, "Todo", { fg = todo_fg, bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@text.todo", { fg = todo_fg, bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@comment.todo", { fg = todo_fg, bg = "NONE", bold = true })

      -- Go の関数だけ濃くする（Treesitter/LSP/legacy/regexに対応）
      local function apply_go_function_highlights()
        local set = vim.api.nvim_set_hl
        local groups = {
          ["Function"] = { fg = "#f38ba8", bold = true },
          ["@function.go"] = { fg = "#f38ba8", bold = true },
          ["@function.call.go"] = { fg = "#f38ba8", bold = true },
          ["@method.go"] = { fg = "#f38ba8", bold = true },
          ["@method.call.go"] = { fg = "#f38ba8", bold = true },
          ["@constructor.go"] = { fg = "#f38ba8", bold = true },
          ["@lsp.type.function"] = { fg = "#f38ba8", bold = true },
          ["@lsp.type.method"] = { fg = "#f38ba8", bold = true },
          ["goFunction"] = { fg = "#f38ba8", bold = true },
          ["goMethod"] = { fg = "#f38ba8", bold = true },
        }
        for group, opts in pairs(groups) do
          set(0, group, opts)
        end
      end

      local function apply_go_function_regex(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        vim.api.nvim_buf_call(bufnr, function()
          if vim.bo.filetype ~= "go" then
            return
          end
          vim.cmd([[
            silent! syntax clear GoFuncName
            silent! syntax clear GoFuncCallName
          ]])
          vim.cmd([[
            syntax match GoFuncName /\v<func\s+(\([^)]*\)\s+)?\zs\k+/
            syntax match GoFuncCallName /\v<\k+\ze\(/ containedin=goBlock,goExpr,goSimpleStmt,goIf,goFor,goSwitch,goCase
          ]])
          vim.api.nvim_set_hl(0, "GoFuncName", { fg = "#f38ba8", bold = true })
          vim.api.nvim_set_hl(0, "GoFuncCallName", { fg = "#f38ba8", bold = true })
          if vim.b.go_func_match_id == nil then
            vim.b.go_func_match_id = vim.fn.matchadd(
              "GoFuncName",
              [[\v<func\s+(\([^)]*\)\s+)?\zs\k+]]
            )
          end
          if vim.b.go_funccall_match_id == nil then
            vim.b.go_funccall_match_id = vim.fn.matchadd(
              "GoFuncCallName",
              [[\v<\k+\ze\(]]
            )
          end
        end)
      end

      apply_go_function_highlights()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        apply_go_function_regex(buf)
      end

      local go_hl = vim.api.nvim_create_augroup("GoFunctionHighlights", { clear = true })
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = go_hl,
        callback = apply_go_function_highlights,
      })
      vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
        group = go_hl,
        callback = function(args)
          if vim.bo[args.buf].filetype ~= "go" then
            return
          end
          apply_go_function_highlights()
          apply_go_function_regex(args.buf)
        end,
      })
      vim.api.nvim_create_autocmd("BufEnter", {
        group = go_hl,
        pattern = "*.go",
        callback = function(args)
          vim.bo[args.buf].filetype = "go"
          vim.bo[args.buf].syntax = "go"
          apply_go_function_highlights()
          apply_go_function_regex(args.buf)
        end,
      })

      vim.api.nvim_create_user_command("ShowHL", function()
        local id = vim.fn.synID(vim.fn.line("."), vim.fn.col("."), 1)
        local name = vim.fn.synIDattr(id, "name")
        local trans = vim.fn.synIDattr(vim.fn.synIDtrans(id), "name")
        vim.notify("HL: " .. name .. " / " .. trans, vim.log.levels.INFO)
      end, {})
      vim.api.nvim_create_autocmd("LspAttach", {
        group = go_hl,
        callback = function(args)
          if vim.bo[args.buf].filetype == "go" then
            apply_go_function_highlights()
          end
        end,
      })
    end,
  },
}
