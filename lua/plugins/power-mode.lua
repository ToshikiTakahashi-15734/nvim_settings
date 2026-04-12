return {
  "axsaucedo/neovim-power-mode",
  config = function()
    require("power-mode").setup({
      particles = { preset = "stars" },
      shake = { enabled = false },
      combo = { enabled = false },
    })
  end,
}
