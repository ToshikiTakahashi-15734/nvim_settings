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
          file_sorter = require('telescope.sorters').get_fuzzy_file,
          generic_sorter = require('telescope.sorters').get_generic_fuzzy_sorter,
          path_display = path_display_filename_first_truncate,
        },
        extensions = {
          frecency = {
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
      
      -- Frecency 拡張を読み込み
      require('telescope').load_extension('frecency')

      local builtin = require('telescope.builtin')
      local pickers = require('telescope.pickers')
      local finders = require('telescope.finders')
      local make_entry = require('telescope.make_entry')
      local conf = require('telescope.config').values
      local action_state = require('telescope.actions.state')
      local Job = require('plenary.job')

      local function get_cwd()
        return vim.fn.getcwd()
      end

      local function normalize_path(path)
        if path == nil or path == '' then
          return ''
        end
        local real = vim.loop.fs_realpath(path)
        return real ~= nil and real or vim.fn.fnamemodify(path, ':p')
      end

      local function get_recent_files_in_cwd()
        local cwd = normalize_path(get_cwd())
        if cwd ~= '' and not vim.endswith(cwd, '/') then
          cwd = cwd .. '/'
        end

        local function in_cwd(path)
          return path ~= '' and vim.startswith(path, cwd)
        end

        local recent = {}
        local seen = {}

        local function add_path(path)
          local normalized = normalize_path(path)
          if normalized == '' or not in_cwd(normalized) then
            return
          end
          if not vim.loop.fs_stat(normalized) then
            return
          end
          if not seen[normalized] then
            seen[normalized] = true
            table.insert(recent, normalized)
          end
        end

        for _, path in ipairs(vim.v.oldfiles) do
          add_path(path)
        end

        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) then
            add_path(vim.api.nvim_buf_get_name(buf))
          end
        end

        return recent
      end

      local function find_files_with_history()
        vim.cmd('silent! wall') -- 先に保存して検索結果を最新に
        local cwd = get_cwd()
        local recent_files = get_recent_files_in_cwd()

        -- 履歴が空のときは cwd 内の全ファイル検索にフォールバック
        if #recent_files == 0 then
          builtin.find_files({ cwd = cwd })
          return
        end

        local function oldfiles_finder()
          return finders.new_table({
            results = recent_files,
            entry_maker = make_entry.gen_from_file({ cwd = cwd }),
          })
        end

        local function switch_to_history(prompt_bufnr)
          local picker = action_state.get_current_picker(prompt_bufnr)
          picker:refresh(oldfiles_finder(), { reset_prompt = false })
        end

        pickers.new({}, {
          prompt_title = '最近参照したファイル',
          finder = oldfiles_finder(),
          sorter = conf.file_sorter({}),
          previewer = conf.file_previewer({}),
          attach_mappings = function(prompt_bufnr, map)
            map('i', '<C-h>', function()
              switch_to_history(prompt_bufnr)
            end)
            map('n', '<C-h>', function()
              switch_to_history(prompt_bufnr)
            end)
            return true
          end,
        }):find()
      end

      local function live_grep_with_history()
        vim.cmd('silent! wall') -- 先に保存して検索結果を最新に
        local cwd = get_cwd()
        local recent_files = get_recent_files_in_cwd()
        -- デフォルトはプロジェクト全体（cwd）。履歴ファイルのみに絞る場合は <C-h>
        local history_dirs = #recent_files > 0 and recent_files or { cwd }

        local function live_grep_finder(search_dirs)
          return finders.new_job(function(prompt)
            if not prompt or prompt == '' then
              return nil
            end
            if #search_dirs == 0 then
              return nil
            end
            local args = vim.deepcopy(conf.vimgrep_arguments)
            table.insert(args, prompt)
            for _, dir in ipairs(search_dirs) do
              table.insert(args, dir)
            end
            return args
          end, make_entry.gen_from_vimgrep({}), nil, cwd)
        end

        local function switch_to_history(prompt_bufnr)
          local picker = action_state.get_current_picker(prompt_bufnr)
          picker:refresh(live_grep_finder(history_dirs), { reset_prompt = false })
        end

        local function switch_to_all(prompt_bufnr)
          local picker = action_state.get_current_picker(prompt_bufnr)
          picker:refresh(live_grep_finder({ cwd }), { reset_prompt = false })
        end

        pickers.new({}, {
          prompt_title = '全文検索（プロジェクト全体）',
          finder = live_grep_finder({ cwd }),
          previewer = conf.grep_previewer({}),
          sorter = conf.generic_sorter({}),
          cwd = cwd,
          attach_mappings = function(prompt_bufnr, map)
            map('i', '<C-a>', function()
              switch_to_all(prompt_bufnr)
            end)
            map('n', '<C-a>', function()
              switch_to_all(prompt_bufnr)
            end)
            -- 履歴ファイルのみに絞る（最近開いたファイルだけ検索）
            map('i', '<C-h>', function()
              switch_to_history(prompt_bufnr)
            end)
            map('n', '<C-h>', function()
              switch_to_history(prompt_bufnr)
            end)
            return true
          end,
        }):find()
      end

      local function combined_search()
        vim.ui.input({ prompt = "検索ワード: " }, function(input)
          if not input or input == "" then
            return
          end

          local cwd = get_cwd()
          local file_results = Job:new({
            command = "rg",
            args = { "--files", "-g", "*" .. input .. "*" },
            cwd = cwd,
          }):sync()

          local grep_results = Job:new({
            command = "rg",
            args = { "--vimgrep", input },
            cwd = cwd,
          }):sync()

          local entries = {}
          for _, path in ipairs(file_results or {}) do
            table.insert(entries, { kind = "file", value = path })
          end
          for _, line in ipairs(grep_results or {}) do
            table.insert(entries, { kind = "grep", value = line })
          end

          vim.fn.setreg("/", input)
          vim.opt.hlsearch = true

          pickers.new({}, {
            prompt_title = "ファイル名 + 全文検索",
            finder = finders.new_table({
              results = entries,
              entry_maker = function(entry)
                if entry.kind == "file" then
                  return {
                    value = entry.value,
                    display = "FILE  " .. entry.value,
                    ordinal = entry.value,
                    filename = entry.value,
                    lnum = 1,
                    col = 1,
                    text = entry.value,
                  }
                end
                local filename, lnum, col, text = entry.value:match("([^:]+):(%d+):(%d+):(.*)")
                if not filename then
                  return nil
                end
                return {
                  value = entry.value,
                  display = "GREP  " .. entry.value,
                  ordinal = entry.value,
                  filename = filename,
                  lnum = tonumber(lnum),
                  col = tonumber(col),
                  text = text,
                }
              end,
            }),
            sorter = conf.generic_sorter({}),
            previewer = conf.grep_previewer({}),
          }):find()
        end)
      end

      -- 1. ファイル名検索（履歴優先・頻度ベース） (スペース + f)
      vim.keymap.set('n', '<leader>f', function()
        require('telescope').extensions.frecency.frecency({ workspace = 'CWD' })
      end, { desc = "ファイル検索（履歴優先）" })

      -- 2. 全文検索（プロジェクト全体） (スペース2回)
      vim.keymap.set('n', '<leader><leader>', live_grep_with_history, { desc = "全文検索（プロジェクト全体）" })

      -- 3. ファイル履歴表示 (スペース + f + h)
      vim.keymap.set('n', '<leader>fh', builtin.oldfiles, { desc = "ファイル履歴" })

      -- 4. 全ファイル検索（履歴無視） (スペース + f + a)
      vim.keymap.set('n', '<leader>fa', builtin.find_files, { desc = "全ファイル検索" })

      -- 5. 全ショートカット（Vim標準+LSP+自分で決めたもの）の表示
      vim.keymap.set('n', '<leader>?', builtin.keymaps, { desc = "Search all keymaps" })


      -- 元々あった設定も残す場合はこちら（不要なら消してOKです）
      vim.keymap.set('n', '<leader>ff', function()
        require('telescope').extensions.frecency.frecency({ workspace = 'CWD' })
      end, {})
      vim.keymap.set('n', '<leader>fg', live_grep_with_history, {})
    end
  }
}

