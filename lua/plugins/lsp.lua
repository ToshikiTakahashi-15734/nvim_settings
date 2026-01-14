return {
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "williamboman/mason.nvim",
      "williamboman/mason-lspconfig.nvim",
      "hrsh7th/cmp-nvim-lsp",
    },
    config = function()
      -- 1. Masonの基本セットアップ
      require("mason").setup()
      require("mason-lspconfig").setup({
          ensure_installed = { "lua_ls", "ts_ls", "eslint", "pyright" },
      })

      -- 2. 補完機能の準備（エラー回避のために安全に取得）
      local capabilities = {}
      local ok, cmp_lsp = pcall(require, "cmp_nvim_lsp")
      if ok then
        capabilities = cmp_lsp.default_capabilities()
      end

      -- 3. LSPサーバーの個別設定
      -- 警告が出る require('lspconfig') ではなく、新しい vim.lsp.config を使用
      local servers = { "lua_ls" }

      for _, server in ipairs(servers) do
        -- Neovim 0.11以降の推奨される書き方
        vim.lsp.config(server, {
          capabilities = capabilities,
        })
        vim.lsp.enable(server)
      end

      -- VSCode風のエラー表示設定
      local signs = { Error = " ", Warn = " ", Hint = "󰠠 ", Info = " " }
      for type, icon in pairs(signs) do
        local hl = "DiagnosticSign" .. type
        vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
      end

      vim.diagnostic.config({
        virtual_text = { prefix = "●" },
        underline = true,
        update_in_insert = false,
        severity_sort = true,
        float = { border = "rounded" },
      })

      -- 4. キーマップ設定
      vim.api.nvim_create_autocmd('LspAttach', {
        callback = function(ev)
          local opts = { buffer = ev.buf }
          vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts) -- 定義へ
          vim.keymap.set('n', '<D-d>',vim.lsp.buf.definition, opts)
          vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
          vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
        end,
      })
    end,
  },
}
