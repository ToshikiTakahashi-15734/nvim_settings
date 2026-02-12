return {
  'akinsho/bufferline.nvim',
  version = "*",
  dependencies = 'nvim-tree/nvim-web-devicons',
  config = function()
    local function safe_tab_close()
      if vim.fn.tabpagenr('$') > 1 then
        vim.cmd('tabclose')
      end
    end

    require("bufferline").setup({
      options = {
        mode = "tabs", -- 「タブ」を表示するモードに設定
        separator_style = "slant", -- 見た目をおしゃれに（斜め切り）
        always_show_bufferline = true,
        close_command = safe_tab_close,
        right_mouse_command = safe_tab_close,
      }
    })
  end
}
