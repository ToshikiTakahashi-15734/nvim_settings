return {
  {
    'nvim-telescope/telescope.nvim',
    tag = '0.1.8',
    dependencies = {
      'nvim-lua/plenary.nvim',
      {
        'nvim-telescope/telescope-frecency.nvim',
        dependencies = { 'kkharji/sqlite.lua' },
      },
      {
        'nvim-telescope/telescope-fzf-native.nvim',
        build = 'make',
      },
    },
    config = function()
      -- 長いパスを「ファイル名 + パス（薄い色で省略表示）」で表示（Cursor風）
      local function path_display_filename_first_truncate(_, path)
        path = path or ""
        local tail = vim.fn.fnamemodify(path, ":t")
        local dir = vim.fn.fnamemodify(path, ":h")
        if dir == "." or dir == "" then
          return tail
        end
        local cwd = vim.fn.getcwd()
        if #dir >= #cwd and dir:sub(1, #cwd) == cwd then
          dir = dir:sub(#cwd + 1):gsub("^[/\\]+", "")
        end
        local max_path = 48
        local display_dir
        if #dir <= max_path then
          display_dir = dir
        else
          local keep = math.max(1, math.floor((max_path - 3) / 2))
          display_dir = dir:sub(1, keep) .. "..." .. dir:sub(-keep)
        end
        local display = tail .. "  " .. display_dir
        local path_start = #tail + 2
        local highlights = {
          { { path_start, #display }, "TelescopeResultsComment" },
        }
        return display, highlights
      end

      require('telescope').setup({
        defaults = {
          preview = {
            treesitter = false,  -- ft_to_lang nil エラー回避（Tree-sitter 未導入 or Neovim 0.11 互換）
          },
          file_sorter = require('telescope.sorters').get_generic_fuzzy_sorter,
          generic_sorter = require('telescope.sorters').get_generic_fuzzy_sorter,
          path_display = path_display_filename_first_truncate,
        },
        extensions = {
          fzf = {
            fuzzy = true,
            override_generic_sorter = true,
            override_file_sorter = true,
            case_mode = "smart_case",
          },
          frecency = {
            db_safe_mode = false,
            show_scores = true,
            show_unindexed = true,
            ignore_patterns = { "*.git/*", "*/tmp/*" },
            workspaces = {
              ["conf"] = vim.fn.expand("~/.config"),
              ["project"] = vim.fn.getcwd(),
            },
          },
        },
      })
      
      -- fzf-native 拡張を読み込み（C実装で高速・高精度なファジーマッチ）
      require('telescope').load_extension('fzf')
      -- Frecency 拡張を読み込み
      require('telescope').load_extension('frecency')

      local builtin = require('telescope.builtin')
      local pickers = require('telescope.pickers')
      local finders = require('telescope.finders')
      local make_entry = require('telescope.make_entry')
      local conf = require('telescope.config').values

      -- nvimの起動ディレクトリ（getcwd）からgit rootを特定
      local function get_cwd()
        local cwd = vim.fn.getcwd()
        local git_root = vim.fn.systemlist("cd " .. vim.fn.shellescape(cwd) .. " && git rev-parse --show-toplevel")[1]
        if vim.v.shell_error == 0 and git_root and git_root ~= "" then
          return git_root
        end
        return cwd
      end

      -- ファイル名検索（プロジェクト全体） (スペース + f)
      -- パスをコピペしても検索できるよう、クエリ内の "/" をスペースに置換してマッチさせる
      vim.keymap.set('n', '<leader>f', function()
        local cwd = get_cwd()
        pickers.new({}, {
          prompt_title = 'ファイル検索（プロジェクト全体）',
          finder = finders.new_oneshot_job(
            { 'fd', '--type', 'file', '--strip-cwd-prefix', '--hidden', '--follow', '--exclude', '.git' },
            { cwd = cwd, entry_maker = make_entry.gen_from_file({ cwd = cwd }) }
          ),
          sorter = conf.file_sorter({}),
          previewer = conf.file_previewer({}),
          on_input_filter_cb = function(prompt)
            return { prompt = prompt:gsub("/", " ") }
          end,
        }):find()
      end, { desc = "ファイル検索（プロジェクト全体）" })

      -- 全文検索（プロジェクト全体） (スペース2回)
      vim.keymap.set('n', '<leader><leader>', function()
        builtin.live_grep({ cwd = get_cwd() })
      end, { desc = "全文検索（プロジェクト全体）" })

      -- 全ショートカット表示
      vim.keymap.set('n', '<leader>?', builtin.keymaps, { desc = "Search all keymaps" })
    end
  }
}

