return {
  {
    "LazyVim/LazyVim",
    init = function()
      -- VimTeX's shared configuration deliberately leaves platform launch
      -- details overridable. macOS has neither Okular nor xdg-open; open
      -- generated PDFs with the native `open` command instead of falling
      -- through to the shared Linux-only fallback.
      vim.g.vimtex_view_method = "general"
      vim.g.vimtex_view_general_viewer = "open"
      vim.g.vimtex_view_general_options = "@pdf"
    end,
  },
}
