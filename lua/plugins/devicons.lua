return {
  "nvim-tree/nvim-web-devicons",
  config = function()
    require("nvim-web-devicons").setup({
      override_by_extension = {
        ["gs"] = {
          icon = string.char(0xef, 0x92, 0x99),
          color = "#f4b400",
          name = "GoogleAppsScript",
        },
      },
    })
  end,
}
