return {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter", -- 【重要】これを追加しないと、インサートモードに入るまで起動しません
    config = function()
        require("copilot").setup({
            suggestion = {
                enabled = true,       -- ★ここを true にする
                auto_trigger = true,  -- 自動で提案を出す
                keymap = {
                    accept = false, -- Tab は completions.lua 側で統合制御
                },
            },
            panel = { enabled = false },
            copilot_node_command = vim.fn.expand('~/.nvm/versions/node/v22.21.1/bin/node'),
        })
    end,
}
