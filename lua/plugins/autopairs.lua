return {
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter", -- 挿入モードに入った時に読み込む
    config = function()
      require("nvim-autopairs").setup({
        check_ts = true, -- Treesitterと連携してより賢く補完する
      })
    end,
  },
}
