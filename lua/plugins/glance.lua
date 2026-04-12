-- glance.nvim がジャンプする際に E325 スワップファイル警告でクラッシュするのを防ぐ
vim.api.nvim_create_autocmd("SwapExists", {
  callback = function()
    vim.v.swapchoice = "e" -- スワップを無視してそのまま開く
  end,
})

-- Cursor風: 参照をカーソル付近のpeekウィンドウで表示
return {
  "DNLHC/glance.nvim",
  event = "LspAttach",
  opts = {
    border = {
      enable = true,
      top_char = "─",
      bottom_char = "─",
    },
    theme = {
      enable = true,
      mode = "auto",
    },
    indent_lines = {
      enable = true,
    },
    winbar = {
      enable = true,
    },
  },
}
