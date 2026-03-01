return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      -- nvim-treesitter v1.x: パーサー管理のみ担当
      require("nvim-treesitter").setup({
        ensure_installed = {
          "lua",
          "vim",
          "vimdoc",
          "query",
          "go",
          "gomod",
          "gosum",
          "php",
          "phpdoc",
          "javascript",
          "typescript",
          "tsx",
          "svelte",
          "html",
          "css",
          "terraform",
          "hcl",
        },
      })

      -- Neovim 0.11+: 組み込みAPIでTreesitterハイライト・インデントを有効化
      vim.api.nvim_create_autocmd("FileType", {
        callback = function(ev)
          local ok = pcall(vim.treesitter.start, ev.buf)
          if ok then
            vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })

      -- インクリメンタル選択
      vim.keymap.set("n", "<C-space>", function()
        require("nvim-treesitter.incremental_selection").init()
      end, { desc = "Start incremental selection" })
      vim.keymap.set("v", "<C-space>", function()
        require("nvim-treesitter.incremental_selection").increment()
      end, { desc = "Increment selection" })
      vim.keymap.set("v", "<bs>", function()
        require("nvim-treesitter.incremental_selection").decrement()
      end, { desc = "Decrement selection" })
    end,
  },
}
