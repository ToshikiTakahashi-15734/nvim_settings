return {
    "stevearc/conform.nvim",
    event = { "BufWritePre" },
    cmd = { "ConformInfo" },
    keys = {
        {
            "<A-S-f>",
            function()
                require("conform").format({ async = true, lsp_fallback = true })
            end,
            mode = "",
            desc = "Format buffer",
        },
    },
    opts = function()
        local util = require("conform.util")

        return {
            formatters_by_ft = {
                javascript = { "eslint_d", "eslint" },
                typescript = { "eslint_d", "eslint" },
                javascriptreact = { "eslint_d", "eslint" },
                typescriptreact = { "eslint_d", "eslint" },
                json = { "prettier" },
                lua = { "stylua" },
                python = { "isort", "black" },
                terraform = { "terraform_fmt" },
                hcl = { "terraform_fmt" },
            },
            formatters = {
                eslint_d = {
                    cwd = util.root_file({
                        ".eslintrc.cjs",
                        ".eslintrc.js",
                        ".eslintrc.json",
                        "package.json",
                        ".git",
                    }),
                },
                eslint = {
                    cwd = util.root_file({
                        ".eslintrc.cjs",
                        ".eslintrc.js",
                        ".eslintrc.json",
                        "package.json",
                        ".git",
                    }),
                },
            },
            format_on_save = {
                timeout_ms = 3000,
                lsp_fallback = true,
                stop_after_first = true,
            },
        }
    end,
}
