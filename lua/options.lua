-- 基本設定
local opt = vim.opt

opt.number = true           -- 行番号を表示
opt.relativenumber = true   -- 相対行番号を表示（移動しやすくなる）
opt.mouse = 'a'             -- マウス操作を有効化
opt.ignorecase = true       -- 検索時に大文字小文字を区別しない
opt.smartcase = true        -- 大文字が含まれる場合は区別する
opt.shiftwidth = 4          -- インデントの幅を4に
opt.tabstop = 4             -- タブの表示幅を4に
opt.expandtab = true        -- タブをスペースに変換
opt.clipboard = "unnamedplus" -- Macのクリップボードと同期
opt.cursorline = true       -- 現在の行を強調
