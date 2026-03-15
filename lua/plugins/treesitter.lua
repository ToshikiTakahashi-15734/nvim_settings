return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      -- nvim-treesitter v1.x: runtime/queries をランタイムパスに追加
      local ts_path = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter/runtime"
      if not vim.list_contains(vim.opt.runtimepath:get(), ts_path) then
        vim.opt.runtimepath:prepend(ts_path)
      end

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
          if pcall(vim.treesitter.start, ev.buf) then
            vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })

      -- インクリメンタル選択（Neovim 0.11+ 組み込みAPI）
      local selection_node = nil
      vim.keymap.set("n", "<C-space>", function()
        selection_node = vim.treesitter.get_node()
        if selection_node then
          local sr, sc, er, ec = selection_node:range()
          vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
          vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
          vim.cmd("normal! gv")
        end
      end, { desc = "Start incremental selection" })
      vim.keymap.set("v", "<C-space>", function()
        if selection_node then
          local parent = selection_node:parent()
          if parent then
            selection_node = parent
          end
        else
          selection_node = vim.treesitter.get_node()
        end
        if selection_node then
          local sr, sc, er, ec = selection_node:range()
          vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
          vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
          vim.cmd("normal! gv")
        end
      end, { desc = "Increment selection" })
      vim.keymap.set("v", "<bs>", function()
        if selection_node then
          local child = selection_node:child(0)
          if child then
            selection_node = child
          end
        end
        if selection_node then
          local sr, sc, er, ec = selection_node:range()
          vim.fn.setpos("'<", { 0, sr + 1, sc + 1, 0 })
          vim.fn.setpos("'>", { 0, er + 1, ec, 0 })
          vim.cmd("normal! gv")
        end
      end, { desc = "Decrement selection" })
    end,
  },
}
