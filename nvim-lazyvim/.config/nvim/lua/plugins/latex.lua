return {
  {
    "lervag/vimtex",
    init = function()
      -- VimTeX owns compilation and build-log navigation. Its latexmk backend
      -- runs continuously by default and handles Biber when the document asks
      -- for it, while project-specific .latexmkrc files remain authoritative.
      vim.g.vimtex_compiler_method = "latexmk"
      vim.g.vimtex_quickfix_open_on_warning = 0

      -- Okular is part of the Fedora KDE baseline and supports forward and
      -- inverse SyncTeX. A platform adapter (for example Fedora WSL) may set a
      -- viewer before this shared fallback without moving platform launch
      -- details into the common editor configuration.
      vim.g.vimtex_view_method = "general"
      if not vim.g.vimtex_view_general_viewer then
        if vim.fn.executable("okular") == 1 then
          vim.g.vimtex_view_general_viewer = "okular"
          vim.g.vimtex_view_general_options = [[--unique file:@pdf\#src:@line@tex]]
        else
          vim.g.vimtex_view_general_viewer = "xdg-open"
          vim.g.vimtex_view_general_options = "@pdf"
        end
      end
    end,
    keys = {
      { "<localleader>ll", "<plug>(vimtex-compile)", desc = "Compile (continuous)", ft = "tex" },
      { "<localleader>lv", "<plug>(vimtex-view)", desc = "View PDF / forward search", ft = "tex" },
      { "<localleader>le", "<plug>(vimtex-errors)", desc = "Build errors", ft = "tex" },
      { "<localleader>lo", "<plug>(vimtex-compile-output)", desc = "Compiler output", ft = "tex" },
      { "<localleader>lt", "<plug>(vimtex-toc-open)", desc = "Document table of contents", ft = "tex" },
      { "<localleader>li", "<plug>(vimtex-info)", desc = "Project info", ft = "tex" },
    },
  },

  {
    "neovim/nvim-lspconfig",
    optional = true,
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers.texlab = vim.tbl_deep_extend("force", opts.servers.texlab or {}, {
        settings = {
          texlab = {
            -- VimTeX/latexmk owns builds, diagnostics parsed from build logs,
            -- and forward search. This prevents duplicate builds on save.
            build = {
              onSave = false,
              forwardSearchAfter = false,
            },
            chktex = {
              onOpenAndSave = false,
              onEdit = false,
            },

            -- Fedora supplies latexindent. TexLab exposes it through the
            -- standard LazyVim formatting command and respects a project-local
            -- .latexindent.yaml via latexindent's --local mode.
            latexFormatter = "latexindent",
            latexindent = {
              modifyLineBreaks = false,
            },
          },
        },
      })
    end,
  },
}
