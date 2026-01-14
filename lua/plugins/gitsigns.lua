return {
  "lewis6991/gitsigns.nvim",
  config = function()
    require('gitsigns').setup({
      -- 変更箇所のプレビューを <leader>hp で見れるように設定例
      on_attach = function(bufnr)
        local gs = package.loaded.gitsigns
        vim.keymap.set('n', '<leader>hp', gs.preview_hunk, { buffer = bufnr, desc = "Git差分をプレビュー" })
      end
    })
  end
}
