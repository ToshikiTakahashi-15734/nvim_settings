return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    require('gitsigns').setup({
      signs = {
        add          = { text = "▎" },
        change       = { text = "▎" },
        delete       = { text = "▁" },
        topdelete    = { text = "▔" },
        changedelete = { text = "▎" },
        untracked    = { text = "┆" },
      },
      current_line_blame = true,
      current_line_blame_opts = {
        delay = 300,
        virt_text_pos = "eol",
      },
      current_line_blame_formatter = "  <author> • <author_time:%Y-%m-%d> • <summary>",
      -- キーバインドは keymaps.lua で一元管理
    })

    -- gitsignsの色をわかりやすく設定
    vim.api.nvim_set_hl(0, "GitSignsAdd", { fg = "#73daca" })
    vim.api.nvim_set_hl(0, "GitSignsChange", { fg = "#7aa2f7" })
    vim.api.nvim_set_hl(0, "GitSignsDelete", { fg = "#f7768e" })
  end
}
