-- フローティングターミナル（Cursor/VSCode風）
return {
  "akinsho/toggleterm.nvim",
  version = "*",
  keys = {
    { "T", '<CMD>ToggleTerm direction=float<CR>', desc = "Toggle floating terminal" },
    { "T", '<CMD>ToggleTerm direction=float<CR>', mode = "t", desc = "Close floating terminal" },
  },
  opts = {
    size = function(term)
      if term.direction == "horizontal" then
        return math.floor(vim.o.lines * 0.3)
      elseif term.direction == "vertical" then
        return math.floor(vim.o.columns * 0.4)
      end
    end,
    shade_terminals = false,
    float_opts = {
      border = "rounded",
      width = function()
        return math.floor(vim.o.columns * 0.5)
      end,
      height = function()
        return math.floor(vim.o.lines * 0.3)
      end,
    },
    highlights = {
      FloatBorder = { link = "FloatBorder" },
    },
  },
}
