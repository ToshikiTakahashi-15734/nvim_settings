return {
  "nvim-tree/nvim-tree.lua",
  version = "*",
  lazy = false,
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  config = function()
    require("nvim-tree").setup({
      view = {
        width = 30,           -- ツリーの横幅
        side = "left",        -- 左側に表示
      },
      filters = {
        dotfiles = false,     -- ドットファイル（.configなど）も表示する
      },
      diagnostics = {
        enable = true,
        show_on_dirs = true,
        show_on_open_dirs = true,
        debounce_delay = 50,
        icons = {
          hint = "󰠠 ",
          info = " ",
          warning = " ",
          error = " ",
        },
      },
    })
  end,
}
