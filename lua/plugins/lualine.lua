return {
  "nvim-lualine/lualine.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  config = function()
    -- 既存の診断表示（options.lua で定義されている場合に利用）
    local function diagnostic_statusline()
      if _G.diagnostic_statusline then
        return _G.diagnostic_statusline()
      end
      return ""
    end

    require("lualine").setup({
      options = {
        theme = "auto", -- 現在のカラースキーム（catppuccin等）に合わせる
        component_separators = { left = "│", right = "│" },
        section_separators = { left = "", right = "" },
        disabled_filetypes = { statusline = { "NvimTree", "lazy" } },
      },
      sections = {
        lualine_a = {
          -- モードを目立たせる（色付き・略称）
          {
            "mode",
            fmt = function(str)
              local mode_map = {
                ["n"] = "NORMAL",
                ["no"] = "N·OP",
                ["nov"] = "N·OP",
                ["noV"] = "N·OP",
                ["no\22"] = "N·OP",
                ["niI"] = "NORMAL",
                ["niR"] = "NORMAL",
                ["niV"] = "NORMAL",
                ["nt"] = "NORMAL",
                ["v"] = "VISUAL",
                ["vs"] = "VISUAL",
                ["V"] = "V-LINE",
                ["Vs"] = "V-LINE",
                ["\22"] = "V-BLOCK",
                ["\22s"] = "V-BLOCK",
                ["s"] = "SELECT",
                ["S"] = "S-LINE",
                ["\19"] = "S-BLOCK",
                ["i"] = "INSERT",
                ["ic"] = "INSERT",
                ["ix"] = "INSERT",
                ["R"] = "REPLACE",
                ["Rc"] = "REPLACE",
                ["Rx"] = "REPLACE",
                ["Rv"] = "V-REPLACE",
                ["Rvc"] = "V-REPLACE",
                ["Rvx"] = "V-REPLACE",
                ["c"] = "COMMAND",
                ["cv"] = "EX",
                ["ce"] = "EX",
                ["r"] = "HIT-ENTER",
                ["rm"] = "MORE",
                ["r?"] = "CONFIRM",
                ["!"] = "SHELL",
                ["t"] = "TERMINAL",
              }
              return mode_map[str] or str:upper()
            end,
          },
        },
        lualine_b = { "branch", "diff" },
        lualine_c = { "filename", "diagnostics" },
        lualine_x = {},
        lualine_y = {
          {
            diagnostic_statusline,
            color = { fg = "#a6e3a1", gui = "bold" },
          },
        },
        lualine_z = { "location", "progress" },
      },
      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_c = { "filename" },
        lualine_x = {},
        lualine_y = {},
        lualine_z = { "location" },
      },
    })
  end,
}
