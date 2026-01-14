return {
  {
    'nvim-telescope/telescope.nvim',
    tag = '0.1.8',
    dependencies = { 'nvim-lua/plenary.nvim' },
    config = function()
      local builtin = require('telescope.builtin')
      
      -- 1. ファイル名検索 (スペース + f)
      vim.keymap.set('n', '<leader>f', builtin.find_files, {})

      -- 2. プロジェクト全体の文字検索 (スペースを2回ポンポン！)
      vim.keymap.set('n', '<leader><leader>', builtin.live_grep, { desc = "プロジェクト内を文字検索" })
      
      -- 3. 全ショートカット（Vim標準+LSP+自分で決めたもの）の表示
      vim.keymap.set('n', '<leader>?', builtin.keymaps, { desc = "Search all keymaps" })

      -- 元々あった設定も残す場合はこちら（不要なら消してOKです）
      vim.keymap.set('n', '<leader>ff', builtin.find_files, {})
      vim.keymap.set('n', '<leader>fg', builtin.live_grep, {})
    end
  }
}

