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
          todo = { "#ff00ff" }, -- neon magenta
          error = { "#ff0000" }, -- vivid red
          info = { "#00ffff" }, -- neon cyan
          warning = { "#ffea00" }, -- bright yellow
          hint = { "#00ff00" }, -- neon green
          default = { "#ff00ff" },
          test = { "#ff87ff" },
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
