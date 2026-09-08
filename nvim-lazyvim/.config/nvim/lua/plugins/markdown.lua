return {
  -- The upstream extra enables markdownlint-cli2 and markdown-toc globally.
  -- Formatting and style policy belong to each project here, while Marksman
  -- remains the editor-owned source of link and document diagnostics.
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = function(_, opts)
      local project_tools = {
        ["markdown-toc"] = true,
        ["markdownlint-cli2"] = true,
      }
      opts.ensure_installed = vim.tbl_filter(function(tool)
        return not project_tools[tool]
      end, opts.ensure_installed or {})
    end,
  },

  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = function(_, opts)
      opts.linters_by_ft = opts.linters_by_ft or {}
      opts.linters_by_ft.markdown = nil
    end,
  },

  -- LazyVim's Markdown extra owns highlighting, Marksman, rendering and
  -- browser preview. This addition fills its table-editing gap.
  {
    "SCJangra/table-nvim",
    ft = { "markdown", "markdown.mdx" },
    opts = {
      mappings = {
        -- Preserve LazyVim's Tab completion/snippet mapping outside tables.
        next = "<M-l>",
        prev = "<M-h>",
        insert_row_up = "<leader>mK",
        insert_row_down = "<leader>mr",
        move_row_up = "<leader>mk",
        move_row_down = "<leader>mj",
        insert_column_left = "<leader>mC",
        insert_column_right = "<leader>mc",
        move_column_left = "<leader>mh",
        move_column_right = "<leader>ml",
        insert_table = "<leader>mt",
        insert_table_alt = false,
        delete_column = "<leader>md",
      },
    },
  },

  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>m", group = "markdown", icon = "" },
      },
    },
  },

  -- Catppuccin can discover this integration automatically. Keep it explicit
  -- so rendered headings, code blocks, and tables follow the selected flavour.
  {
    "catppuccin/nvim",
    optional = true,
    opts = {
      integrations = {
        render_markdown = true,
      },
    },
  },
}
