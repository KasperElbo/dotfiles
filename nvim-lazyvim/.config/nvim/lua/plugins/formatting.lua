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

        -- LazyVim's Prettier extra maps the filetypes Prettier declares
        -- support for, including json, jsonc, yaml, markdown, and the web
        -- filetypes. Only Angular's separate template filetype needs adding.
        htmlangular = { "prettier" },

        -- Mason supplies the editor-facing Ruff binary. A project's
        -- pyproject.toml remains the source of formatting and lint rules.
        python = { "ruff_format" },
      },
    },
  },
}
