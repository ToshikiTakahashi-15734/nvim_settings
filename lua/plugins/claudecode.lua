return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal = {
      snacks_win_opts = {
        keys = {
          -- Claude ターミナル内で Alt+Space を押すと左のエディタにフォーカスを戻す
          claude_focus_back = {
            "<A-Space>",
            function(self)
              self:hide()
            end,
            mode = "t",
            desc = "エディタにフォーカスを戻す",
          },
        },
      },
    },
  },
  keys = {
    -- Claude Code を開く/閉じる
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Claude Code を開く/閉じる" },
    -- Claude Code にフォーカス（Ctrl+\\ と同じ）
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code にフォーカス" },
    -- 現在のバッファをコンテキストに追加
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "現在のバッファをコンテキストに追加" },
    -- 選択範囲を Claude に送る（ビジュアルで選択してから）
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", desc = "選択範囲を Claude に送る", mode = "v" },
    -- ファイルツリーで選択したファイルを追加 (NvimTree 等)
    {
      "<leader>at",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "ファイルツリーで選択したファイルを追加",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },
    -- Claude の diff を採用
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Claude の diff を採用" },
    -- diff を却下
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "diff を却下" },
  },

}
