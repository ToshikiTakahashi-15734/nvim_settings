return {
  "sindrets/diffview.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
  -- キーバインドは keymaps.lua で一元管理
  config = function()
    require("diffview").setup({
      enhanced_diff_hl = false,
      hooks = {
        -- 開いた直後に diff パネルが "-1" になるタイミング問題を回避
        view_opened = function(view)
          vim.schedule(function()
            local lib = require("diffview.lib")
            local cv = lib.get_current_view()
            if cv then
              cv:update_files()
            end
          end)
        end,
      },
      view = {
        default = {
          layout = "diff2_horizontal",
        },
        merge_tool = {
          layout = "diff3_horizontal",
        },
        file_history = {
          layout = "diff2_horizontal",
        },
      },
      file_panel = {
        listing_style = "tree",
        tree_options = {
          flatten_dirs = true,
          folder_statuses = "only_folded",
        },
        win_config = {
          position = "left",
          width = 35,
        },
      },
    })
  end,
}
