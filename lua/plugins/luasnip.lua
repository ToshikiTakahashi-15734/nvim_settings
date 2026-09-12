-- ============================================================
-- LuaSnip: 短い呪文から雛形を展開するスニペット機構
-- ============================================================
-- 例) SQLファイルで "select" と打って補完候補から選ぶと、
--     SELECT / FROM の雛形が1行で展開される。
--     <Tab> で次の穴へジャンプ、<S-Tab> で前の穴へ戻る。
--
-- スニペットの中身は lua/snippets/ 配下で定義する。
-- ============================================================

return {
    {
        "L3MON4D3/LuaSnip",
        version = "v2.*",
        -- 読み込みタイミングは nvim-cmp の dependencies から引っ張られる
        -- （lua/plugins/completions.lua を参照）
        lazy = true,
        config = function()
            local ls = require("luasnip")

            ls.setup({
                -- スニペットから抜けた後も履歴を保持し、戻れるようにする
                history = true,
                -- 入力に追従してノードを更新する
                update_events = "TextChanged,TextChangedI",
                -- 使い終わったスニペットの追跡を解除する
                delete_check_events = "TextChanged",
            })

            -- 自作スニペット定義を読み込む
            require("snippets.sql")

            -- ====================================================
            -- SQLバッファでは、空の穴に飛んだ瞬間に候補を自動で出す
            -- ====================================================
            -- <Tab> でテーブル名やカラム名の穴に飛んだとき、
            -- 何も打たなくてもDBのスキーマ候補が出るようにする。
            -- 既定値が入っている穴（選択状態）では邪魔になるため、
            -- 挿入モードのときだけ発火させる。
            vim.api.nvim_create_autocmd("User", {
                pattern = "LuasnipInsertNodeEnter",
                callback = function()
                    local ft = vim.bo.filetype
                    if ft ~= "sql" and ft ~= "mysql" and ft ~= "plsql" then
                        return
                    end
                    -- 選択モード（既定値が選ばれている状態）では出さない
                    if vim.fn.mode() ~= "i" then
                        return
                    end
                    local ok, cmp = pcall(require, "cmp")
                    if ok then
                        cmp.complete()
                    end
                end,
            })
        end,
    },
}
