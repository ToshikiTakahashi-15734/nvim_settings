return {
  {
    "xiyaowong/transparent.nvim",
    lazy = false,
    config = function()
      require("transparent").setup({
        -- 透明にしたい項目を指定
        extra_groups = {
          "NormalFloat", -- 浮き上がるウィンドウ
          "NvimTreeNormal", -- ファイルツリー
          "NeoTreeNormal",
          "LineNr", -- 行番号
          "SignColumn", -- エラーアイコンが出る列
        },
      })
      -- 起動時に透明化を有効にする
      vim.cmd("TransparentEnable")
    end,
  },
}
