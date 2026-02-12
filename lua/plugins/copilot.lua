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
                    accept = "<Tab>", -- Tabキーで確定する設定
                    -- accept = "<C-l>", -- もしTabが競合する場合は Ctrl+l などに変更
                },
            },
            panel = { enabled = false },
            copilot_node_command = vim.fn.expand('~/.nvm/versions/node/v22.21.1/bin/node'),
        })
    end,
}
