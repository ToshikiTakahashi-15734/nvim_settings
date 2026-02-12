return {
  {
    "folke/todo-comments.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    event = "VeryLazy",
    config = function()
      require("todo-comments").setup({
        signs = true,
        keywords = {
          TODO = { icon = "T", color = "todo" },
          FIX = { icon = "F", color = "error" },
          NOTE = { icon = "N", color = "info" },
        },
        colors = {
          todo = { "#000000", "#ff00ff" }, -- neon magenta
          error = { "#000000", "#ff0000" }, -- vivid red
          info = { "#000000", "#00ffff" }, -- neon cyan
          warning = { "#000000", "#ffea00" }, -- bright yellow
          hint = { "#000000", "#00ff00" }, -- neon green
          default = { "#000000", "#ff00ff" },
          test = { "#000000", "#ff87ff" },
        },
        highlight = {
          before = "",
          keyword = "bg",
          after = "",
          pattern = [[.*<(KEYWORDS)\s*:]],
        },
      })
    end,
  },
}
