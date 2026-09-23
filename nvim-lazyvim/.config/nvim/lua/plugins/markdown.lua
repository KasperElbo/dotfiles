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

  -- The preview is served by a prebuilt binary the plugin's build downloads.
  -- The extra's build calls mkdp#util#install(), which starts that download in
  -- a terminal job and returns at once, so a headless install quits before it
  -- finishes and leaves app/bin empty; the preview then opens no browser and
  -- says nothing. Run upstream's own script to completion instead, at the
  -- version the locked commit names, and fail the build unless the server it
  -- should leave behind answers with that version. common/lib/markdown-preview.sh
  -- holds the same rule for the installer and the verifiers.
  {
    "iamcco/markdown-preview.nvim",
    optional = true,
    build = function(plugin)
      require("lazy").load({ plugins = { plugin.name } })
      local package = vim.json.decode(table.concat(vim.fn.readfile(plugin.dir .. "/package.json"), "\n"))
      local function ready()
        return vim.trim(vim.fn["mkdp#util#pre_build_version"]()) == package.version
      end
      if ready() then
        return
      end
      -- network-source: markdown-preview-server
      local result = vim.system({ "./install.sh", "v" .. package.version }, { cwd = plugin.dir .. "/app", text = true }):wait()
      if result.code ~= 0 or not ready() then
        error(
          ("markdown-preview.nvim: the preview server v%s was not installed (install.sh exited %d)\n%s%s"):format(
            package.version,
            result.code,
            result.stdout or "",
            result.stderr or ""
          )
        )
      end
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
