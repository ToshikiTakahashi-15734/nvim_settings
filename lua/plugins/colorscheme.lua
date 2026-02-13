return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    config = function()
      require("catppuccin").setup({
        flavour = "mocha",
        transparent_background = true,
        custom_highlights = function()
          return {
            -- Cursor風カラー: 関数（黄色）
            Function = { fg = "#DCDCAA" },
            ["@function"] = { fg = "#DCDCAA" },
            ["@function.call"] = { fg = "#DCDCAA" },
            ["@method"] = { fg = "#DCDCAA" },
            ["@method.call"] = { fg = "#DCDCAA" },
            ["@constructor"] = { fg = "#DCDCAA" },
            ["@lsp.type.function"] = { fg = "#DCDCAA" },
            ["@lsp.type.method"] = { fg = "#DCDCAA" },
            -- キーワード（青）
            Keyword = { fg = "#569CD6" },
            ["@keyword"] = { fg = "#569CD6" },
            -- 文字列（オレンジ）
            String = { fg = "#CE9178" },
            ["@string"] = { fg = "#CE9178" },
            -- 型名（ティール）
            Type = { fg = "#4EC9B0" },
            ["@type"] = { fg = "#4EC9B0" },
            ["@type.builtin"] = { fg = "#4EC9B0" },
            -- 変数（ライトブルー）
            ["@variable"] = { fg = "#9CDCFE" },
            -- コメント（緑）
            Comment = { fg = "#6A9955" },
            -- 数値（ライトグリーン）
            Number = { fg = "#B5CEA8" },
            -- 制御フロー（パープル）
            ["@keyword.operator"] = { fg = "#C586C0" },
            ["@keyword.return"] = { fg = "#C586C0" },
            -- 演算子（白）
            Operator = { fg = "#D4D4D4" },
            -- 定数（ブルー）
            ["@constant"] = { fg = "#4FC1FF" },
            ["@constant.builtin"] = { fg = "#4FC1FF" },
          }
        end,
      })
      vim.cmd("colorscheme catppuccin")

      -- TODO を見やすくする
      local todo_fg = "#ffd75f" -- bright yellow for dark background
      vim.api.nvim_set_hl(0, "Todo", { fg = todo_fg, bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@text.todo", { fg = todo_fg, bg = "NONE", bold = true })
      vim.api.nvim_set_hl(0, "@comment.todo", { fg = todo_fg, bg = "NONE", bold = true })
    end,
  },
}
