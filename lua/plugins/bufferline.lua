return {
  'akinsho/bufferline.nvim',
  version = "*",
  dependencies = 'nvim-tree/nvim-web-devicons',
  config = function()
    require("bufferline").setup({
      options = {
        mode = "tabs", -- 「タブ」を表示するモードに設定
        separator_style = "slant", -- 見た目をおしゃれに（斜め切り）
        always_show_bufferline = true,
      }
    })
  end
}
