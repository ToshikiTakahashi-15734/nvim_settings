-- 基本設定
local opt = vim.opt

opt.number = true           -- 行番号を表示
opt.relativenumber = true   -- 相対行番号を表示（移動しやすくなる）
opt.mouse = 'a'             -- マウス操作を有効化
opt.ignorecase = true       -- 検索時に大文字小文字を区別しない
opt.smartcase = true        -- 大文字が含まれる場合は区別する
opt.hlsearch = true         -- 検索結果をハイライト
opt.incsearch = true        -- 検索中にインクリメンタル表示
opt.autoread = true         -- 外部でファイルが変更されたら自動で再読み込み
opt.autowrite = true        -- 可能なら自動保存
opt.autowriteall = true     -- バッファ全体を自動保存
opt.shiftwidth = 4          -- インデントの幅を4に
opt.tabstop = 4             -- タブの表示幅を4に
opt.expandtab = true        -- タブをスペースに変換
opt.clipboard = "unnamedplus" -- Macのクリップボードと同期
opt.cursorline = true       -- 現在の行を強調
opt.wrap = false            -- 長い行を折り返さない（横スクロールで表示）
opt.laststatus = 3          -- ステータスラインを常に表示
opt.timeoutlen = 1000       -- マッピングの待機時間（<leader>cl などの連続入力向け）
vim.cmd("syntax on")

-- ステータスラインに診断件数と最初のエラー/警告を表示
_G.diagnostic_statusline = function()
    local diagnostics = vim.diagnostic.get(0)
    local counts = { error = 0, warn = 0 }
    local first = nil
    for _, d in ipairs(diagnostics) do
        if d.severity == vim.diagnostic.severity.ERROR then
            counts.error = counts.error + 1
            if not first or first.severity > d.severity then
                first = d
            end
        elseif d.severity == vim.diagnostic.severity.WARN then
            counts.warn = counts.warn + 1
            if not first then
                first = d
            end
        end
    end
    if first then
        local line = first.lnum + 1
        local message = first.message:gsub("%s+", " ")
        return string.format("E:%d W:%d  L%d: %s", counts.error, counts.warn, line, message)
    end
    return string.format("E:%d W:%d", counts.error, counts.warn)
end

opt.statusline = "%f %m%r%h%w%=%{v:lua.diagnostic_statusline()} %l/%L:%c"