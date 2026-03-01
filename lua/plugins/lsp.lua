return {
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
      "folke/trouble.nvim",
    },
    config = function()
      -- 1. Masonの基本セットアップ
      require("mason").setup()
      require("mason-lspconfig").setup({
          ensure_installed = { "lua_ls", "ts_ls", "eslint", "pyright", "phpactor", "terraformls", "gopls", "svelte" },
      })

      -- 2. 補完機能の準備（エラー回避のために安全に取得）
      local capabilities = {}
      local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      if ok then
        capabilities = cmp_lsp.default_capabilities()
      end

      -- 3. LSPサーバーの個別設定（新しいAPIを使用）
      local function find_root(fname)
        return vim.fs.root(fname, {
          "packages/frontend-kaibiz/tsconfig.json",
          "tsconfig.json",
          "package.json",
          ".git"
        }) or vim.fn.getcwd()
      end

      -- TypeScript LSP設定
      local mason_ts = vim.fn.stdpath("data") .. "/mason/bin/typescript-language-server"
      local ts_cmd = vim.fn.executable(mason_ts) == 1 and mason_ts or "typescript-language-server"
      vim.lsp.config("ts_ls", {
        cmd = { ts_cmd, "--stdio" },
        root_dir = find_root,
        capabilities = capabilities,
        filetypes = {
          "javascript",
          "javascriptreact",
          "javascript.jsx",
          "typescript",
          "typescriptreact",
          "typescript.tsx",
        },
        single_file_support = true,
        autostart = true,
      })
      vim.lsp.enable("ts_ls")

      -- Svelte LSP設定
      local mason_svelte = vim.fn.stdpath("data") .. "/mason/bin/svelte-language-server"
      local svelte_cmd = vim.fn.executable(mason_svelte) == 1 and mason_svelte or "svelte-language-server"
      vim.lsp.config("svelte", {
        cmd = { svelte_cmd, "--stdio" },
        root_dir = find_root,
        capabilities = capabilities,
        filetypes = { "svelte" },
        single_file_support = true,
        autostart = true,
      })
      vim.lsp.enable("svelte")

      -- その他のLSP設定
      -- phpactor（PHPStan をグローバルで有効化）
      vim.lsp.config("phpactor", {
        capabilities = capabilities,
        autostart = true,
        init_options = {
          ["language_server_phpstan.enabled"] = true,
        },
      })
      vim.lsp.enable("phpactor")

      local other_servers = { "lua_ls", "terraformls", "gopls" }
      for _, server in ipairs(other_servers) do
        vim.lsp.config(server, {
          capabilities = capabilities,
          autostart = true,
        })
        vim.lsp.enable(server)
      end

      -- TypeScript/JavaScript で ts_ls が付いていなければ明示的に起動（定義ジャンプを可能にする）
      local function ensure_ts_ls(bufnr)
        local ft = vim.bo[bufnr].filetype
        local ts_filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact", "javascript.jsx", "typescript.tsx" }
        if not vim.tbl_contains(ts_filetypes, ft) then
          return
        end
        local ts_clients = vim.lsp.get_clients({ bufnr = bufnr, name = "ts_ls" })
        if #ts_clients > 0 then
          return
        end
        local fname = vim.api.nvim_buf_get_name(bufnr)
        local root = find_root(fname) or vim.fn.fnamemodify(fname, ":p:h")
        local mason_ts = vim.fn.stdpath("data") .. "/mason/bin/typescript-language-server"
        local ts_cmd = vim.fn.executable(mason_ts) == 1 and mason_ts or "typescript-language-server"
        vim.lsp.start({
          name = "ts_ls",
          cmd = { ts_cmd, "--stdio" },
          root_dir = root,
          capabilities = capabilities,
          single_file_support = true,
        }, { bufnr = bufnr })
      end

      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "javascript", "javascriptreact", "javascript.jsx", "typescript", "typescriptreact", "typescript.tsx" },
        callback = function(args)
          ensure_ts_ls(args.buf)
        end,
      })

      -- 既に開いている .ts/.js バッファにも ts_ls を付ける（LspAttach 前で付いていなかった場合の救済）
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client and client.name == "eslint" then
            vim.defer_fn(function()
              ensure_ts_ls(ev.buf)
            end, 100)
          end
        end,
      })

      -- Svelteファイルを開いたときにTypeScript LSPも起動
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "svelte" },
        callback = function(args)
          local filename = vim.api.nvim_buf_get_name(args.buf)
          local ts_clients = vim.lsp.get_clients({ bufnr = args.buf, name = "ts_ls" })
          if #ts_clients == 0 then
            local mason_ts = vim.fn.stdpath("data") .. "/mason/bin/typescript-language-server"
            local ts_cmd = vim.fn.executable(mason_ts) == 1 and mason_ts or "typescript-language-server"
            vim.lsp.start({
              name = "ts_ls",
              cmd = { ts_cmd, "--stdio" },
              root_dir = find_root(filename),
              capabilities = capabilities,
              single_file_support = true,
            }, { bufnr = args.buf })
          end
        end,
      })

      vim.diagnostic.config({
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = " ",
            [vim.diagnostic.severity.WARN] = " ",
            [vim.diagnostic.severity.HINT] = " ",
            [vim.diagnostic.severity.INFO] = " ",
          },
        },
        virtual_text = false,  -- 行末のエラー表示は出さない
        underline = true,     -- エラー箇所の下線はそのまま
        update_in_insert = false,
        severity_sort = true,
        float = { border = "rounded" },
      })

      -- カーソルを一定時間止めたときに現在行の診断をフロート表示（VSCodeのホバー風）
      vim.opt.updatetime = 300  -- ホバー表示までの待ち時間（ms）
      vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
        callback = function()
          vim.diagnostic.open_float(nil, { focus = false, scope = "cursor", border = "rounded" })
        end,
      })

      -- diffview バッファで LSP 操作を実ファイルに切り替えて実行するヘルパー
      local function with_real_file(callback)
        local bufname = vim.api.nvim_buf_get_name(0)
        if not bufname:match("^diffview://") then
          callback()
          return
        end

        local ok_dv, lib = pcall(require, "diffview.lib")
        if not ok_dv then
          callback()
          return
        end

        local view = lib.get_current_view()
        if not view then
          callback()
          return
        end

        local file = view:infer_cur_file()
        if not file or not file.absolute_path then
          callback()
          return
        end

        local cursor = vim.api.nvim_win_get_cursor(0)
        vim.cmd("edit " .. vim.fn.fnameescape(file.absolute_path))
        pcall(vim.api.nvim_win_set_cursor, 0, cursor)
        vim.defer_fn(function()
          callback()
        end, 150)
      end

      -- VSCode風の小窓レイアウト（Telescope の dropdown テーマ）
      local small_win_opts = {
        reuse_win = true,
        layout_config = {
          height = 0.35,
          width = 0.7,
          prompt_position = "top",
          preview_cutoff = 1,
        },
        border = true,
        borderchars = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" },
      }

      -- 4. キーマップ設定とセマンティックハイライト
      vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(ev)
          local opts = { buffer = ev.buf }
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          
          -- キーマップ設定（定義・参照とも小窓で表示）
          vim.keymap.set('n', 'gd', function()
            with_real_file(function()
              require('telescope.builtin').lsp_definitions(vim.tbl_extend("force", small_win_opts, {}))
            end)
          end, vim.tbl_extend("force", opts, { desc = "Go to definition (small window)" }))
          vim.keymap.set('n', '<D-d>', function()
            with_real_file(function()
              require('telescope.builtin').lsp_definitions(vim.tbl_extend("force", small_win_opts, {}))
            end)
          end, vim.tbl_extend("force", opts, { desc = "Go to definition (small window)" }))
          -- 参照一覧をCursor風のpeekウィンドウで表示
          vim.keymap.set('n', 'gr', function()
            with_real_file(function()
              vim.cmd('Glance references')
            end)
          end, vim.tbl_extend("force", opts, { desc = "References (peek window)" }))
          vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
          vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
          -- 現在行の診断を枠付きフロートで表示（VSCodeのホバー風）
          vim.keymap.set('n', 'K', function()
            vim.diagnostic.open_float(nil, { scope = "cursor", border = "rounded" })
          end, vim.tbl_extend("force", opts, { desc = "Show diagnostic in float" }))

          -- セマンティックハイライトを有効化（LSPの色付け）
          if client and client.server_capabilities.semanticTokensProvider then
            vim.lsp.semantic_tokens.start(ev.buf, ev.data.client_id)
          end
        end,
      })
    end,
  },
}
