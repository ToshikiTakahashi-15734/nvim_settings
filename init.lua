vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.opt.clipboard = "unnamedplus"
vim.opt.termguicolors = true

-- lua/options.lua を読み込む
require("options")
-- lua/keymaps.lua を読み込む
require("keymaps")
-- コメント・文字列外では全角を半角に自動変換
require("zenkaku")

-- lazy.nvimのインストールスクリプト
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
end
vim.opt.rtp:prepend(lazypath)

-- 前に書いたrequireをこの下に移動させる
require("options")
require("keymaps")
require("zenkaku")

-- pluginsフォルダの中身を読み込む設定
require("lazy").setup("plugins")

vim.opt.clipboard = "unnamedplus"

-- ==========================================
-- 外部変更の自動再読み込み（Claude Code 等）
-- ==========================================
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    pattern = "*",
    callback = function()
        if vim.fn.getcmdwintype() == "" then
            vim.cmd("checktime")
        end
    end,
})

-- ==========================================
-- Mac標準ターミナルの背景色バグ修正パッチ
-- ==========================================
vim.api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    callback = function()
        -- コメントやキーワードの「斜体(italic)」を強制的にオフにする
        -- これにより、Macターミナルが勝手に背景色をつけるのを防ぎます
        vim.api.nvim_set_hl(0, "Comment", { italic = false })
        vim.api.nvim_set_hl(0, "Keyword", { italic = false })
        vim.api.nvim_set_hl(0, "Type", { italic = false })
        vim.api.nvim_set_hl(0, "Identifier", { italic = false })
        vim.api.nvim_set_hl(0, "Boolean", { italic = false })
    end,
})
