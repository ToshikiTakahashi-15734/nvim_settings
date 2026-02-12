return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      local ok, configs = pcall(require, "nvim-treesitter.configs")
      if not ok then
        return
      end
      configs.setup({
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
          "terraform",
          "hcl",
        },
        highlight = {
          enable = true,
          -- Treesitterが使えない環境でも色が出るように保険
          additional_vim_regex_highlighting = true,
          -- より詳細なハイライトを有効化
          disable = {},
        },
        indent = { enable = true },
        -- インクリメンタル選択を有効化
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "<C-space>",
            node_incremental = "<C-space>",
            scope_incremental = "<nop>",
            node_decremental = "<bs>",
          },
        },
      })
    end,
  },
}
