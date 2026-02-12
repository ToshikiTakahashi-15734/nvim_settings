-- VSCode風: 参照を右側パネルでツリー表示（ファイル別グループ・折りたたみ可能）
return {
  "folke/trouble.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  opts = {
    modes = {
      lsp_references = {
        params = { include_declaration = true },
        win = { position = "right", size = 0.35 },
      },
    },
    auto_close = true,
    auto_preview = true,
    follow = true,
    indent_guides = true,
  },
}
