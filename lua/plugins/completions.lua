return {
  {
    "hrsh7th/nvim-cmp",
    lazy = false, -- 起動時にすぐに読み込む
    priority = 100, -- 優先度を上げる
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      -- スニペットを補完候補として出すための連携
      -- （LuaSnip 本体の設定は lua/plugins/luasnip.lua）
      "L3MON4D3/LuaSnip",
      "saadparwaiz1/cmp_luasnip",
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")

      cmp.setup({
        snippet = {
          -- スニペット形式の補完を LuaSnip で展開する。
          -- LSPが返すスニペットも、自作スニペットもここを通る。
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ['<C-Space>'] = cmp.mapping.complete(),
          -- <Tab> で候補を選んでから <CR> で確定する。
          -- select = true にすると「候補が出ている状態で改行しただけ」で
          -- 先頭候補が確定してしまい、SQL で SELECT と打って改行した瞬間に
          -- select スニペットが暴発する。それを防ぐため false にしている。
          ['<CR>'] = cmp.mapping.confirm({ select = false }),
          ['<Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()             -- 候補が出ていれば次の候補へ
            elseif luasnip.expand_or_locally_jumpable() then
              luasnip.expand_or_jump()           -- スニペット内なら次の穴へ
            else
              fallback()
            end
          end, { 'i', 's' }),
          ['<S-Tab>'] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()             -- 候補が出ていれば前の候補へ
            elseif luasnip.locally_jumpable(-1) then
              luasnip.jump(-1)                   -- スニペット内なら前の穴へ
            else
              fallback()
            end
          end, { 'i', 's' }),
        }),
        sources = cmp.config.sources({
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
          { name = 'buffer' },
          { name = 'path' },
        })
      })
    end,
  }
}
