return {
  {
    "ahmedkhalf/project.nvim",
    config = function()
      require("project_nvim").setup({
        -- WanderAI の下の各ディレクトリをプロジェクトとして認識させる
        manual_mode = false,
        detection_methods = { "pattern" },
        patterns = { ".git", "_darcs", ".hg", ".bzr", ".svn", "Makefile", "package.json" },
        -- 検索対象から除外したいものがあれば
        ignore_lsp = {},
        exclude_dirs = {},
        show_hidden = false,
      })
    end
  }
}
