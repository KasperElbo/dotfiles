return {
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters = {
        -- CSharpier stays owned by the .NET project's local tool manifest and
        -- is invoked through `dotnet csharpier`; see lua/config/csharpier.lua.
        csharpier = require("config.csharpier").formatter(),
      },
      formatters_by_ft = {
        cs = { "csharpier" },

        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },
        html = { "prettier" },
        htmlangular = { "prettier" },
        css = { "prettier" },
        scss = { "prettier" },
        json = { "prettier" },
        jsonc = { "prettier" },
        yaml = { "prettier" },
        markdown = { "prettier" },

        -- Mason supplies the editor-facing Ruff binary. A project's
        -- pyproject.toml remains the source of formatting and lint rules.
        python = { "ruff_format" },
      },
    },
  },
}
