-- コードを書くときは基本的に半角で入力したいための設定
-- 1. Neovim にカーソル（フォーカス）が当たったときだけ英数（半角）に自動切り替え
-- 2. コメント・文字列の外で全角を打つと半角に自動変換

-- ========== 1. フォーカス時に英数へ切り替え ==========
-- (A) im-select があれば使用: brew install im-select
-- (B) なければ osascript で英数キー(keyCode 102)を送信（要：システム環境設定→セキュリティ→アクセシビリティでターミナル/Neovimを許可）

local IM_HANKAKU = "com.apple.keylayout.ABC"  -- 英数（Google日本語なら "com.google.inputmethod.Japanese.Roman"）

local function switch_to_hankaku_ime()
  if vim.fn.has("mac") ~= 1 then
    return
  end
  -- (A) im-select を試す
  for _, path in ipairs({ "/opt/homebrew/bin/im-select", "/usr/local/bin/im-select" }) do
    if vim.fn.executable(path) == 1 then
      vim.fn.jobstart({ path, IM_HANKAKU }, { detach = true })
      return
    end
  end
  -- (B) フォールバック: 英数キーを送る（初回はアクセシビリティ許可が求められることがある）
  vim.schedule(function()
    vim.fn.jobstart({
      "osascript", "-l", "JavaScript",
      "-e", 'Application("System Events").keyCode(102)',
    }, { detach = true })
  end)
end

-- Neovim にカーソル（フォーカス）が当たったときだけ半角に（Insert 時は発火しない）
vim.api.nvim_create_autocmd("FocusGained", {
  pattern = "*",
  callback = switch_to_hankaku_ime,
})

-- ========== 2. コメント・文字列の外では全角 → 半角に自動変換 ==========
local function is_in_comment_or_string()
    local line = vim.fn.line(".")
    local col = vim.fn.col(".")
    if line < 1 or col < 1 then
      return false
    end
    local syn_id = vim.fn.synID(line, col, 1)
    if syn_id == 0 then
      return false
    end
    local name = vim.fn.synIDattr(syn_id, "name") or ""
    return name:match("Comment") or name:match("String")
  end
  
  local function zenkaku_to_hankaku(char)
    local code = vim.fn.char2nr(char)
    -- 全角スペース U+3000
    if code == 0x3000 then
      return " "
    end
    -- 全角ASCIIブロック U+FF01 ～ U+FF5E → U+0021 ～ U+007E
    if code >= 0xFF01 and code <= 0xFF5E then
      return vim.fn.nr2char(code - 0xFEE0)
    end
    -- その他の全角（数字・英字の別ブロックなど）も一応変換
    -- ０-９ U+FF10-U+FF19
    if code >= 0xFF10 and code <= 0xFF19 then
      return vim.fn.nr2char(code - 0xFEE0)
    end
    -- Ａ-Ｚ U+FF21-U+FF3A
    if code >= 0xFF21 and code <= 0xFF3A then
      return vim.fn.nr2char(code - 0xFEE0)
    end
    -- ａ-ｚ U+FF41-U+FF5A
    if code >= 0xFF41 and code <= 0xFF5A then
      return vim.fn.nr2char(code - 0xFEE0)
    end
    return nil -- 変換対象外（日本語などはそのまま）
  end
  
  local function is_zenkaku_convertible(char)
    return zenkaku_to_hankaku(char) ~= nil
  end
  
  vim.api.nvim_create_autocmd("InsertCharPre", {
    pattern = "*",
    callback = function()
      local char = vim.v.char
      if not char or #char == 0 then
        return
      end
      if not is_zenkaku_convertible(char) then
        return
      end
      if is_in_comment_or_string() then
        return -- コメント・文字列内はそのまま
      end
      local hankaku = zenkaku_to_hankaku(char)
      if hankaku then
        vim.v.char = hankaku
      end
    end,
  })
  