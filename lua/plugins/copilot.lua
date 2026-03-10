-- ローカルAIコード補完 (Ollama + qwen2.5-coder)
-- GitHub Copilot の代替としてローカルで動作
return {
    "milanglacier/minuet-ai.nvim",
    dependencies = {
        "nvim-lua/plenary.nvim",
    },
    lazy = false,
    config = function()
        require("minuet").setup({
            -- Ollama の OpenAI互換FIMエンドポイントを使用
            provider = "openai_fim_compatible",

            -- ローカル実行なので1つの補完で十分
            n_completions = 1,

            -- コンテキストを小さくして高速化
            context_window = 2048,

            -- ローカル実行なので待ち時間を最小化
            throttle = 0,
            debounce = 150,
            request_timeout = 3,

            -- ゴーストテキスト表示（Copilot風のインライン補完）
            virtualtext = {
                auto_trigger_ft = { '*' }, -- 全ファイルタイプで有効
                keymap = {
                    accept = "<Tab>",       -- Tab で補完を受け入れ
                    accept_line = "<A-a>",  -- 1行だけ受け入れ
                    prev = "<A-[>",         -- 前の候補
                    next = "<A-]>",         -- 次の候補
                    dismiss = "<A-e>",      -- 候補を消す
                },
            },

            -- Ollama プロバイダー設定
            provider_options = {
                openai_fim_compatible = {
                    api_key = "TERM", -- Ollamaは認証不要（ダミー値）
                    name = "Ollama",
                    end_point = "http://localhost:11434/v1/completions",
                    model = "qwen2.5-coder:7b-base",
                    optional = {
                        max_tokens = 64,
                        top_p = 0.9,
                    },
                    -- Qwen2.5-Coder の FIM トークンテンプレート
                    template = {
                        prompt = function(context_before_cursor, context_after_cursor, _)
                            return "<|fim_prefix|>"
                                .. context_before_cursor
                                .. "<|fim_suffix|>"
                                .. context_after_cursor
                                .. "<|fim_middle|>"
                        end,
                        suffix = false,
                    },
                },
            },
        })
    end,
}
