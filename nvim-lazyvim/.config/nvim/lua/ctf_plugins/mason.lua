return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    opts = function(_, opts)
      if vim.env.DOTFILES_MASON_BOOTSTRAP == "1" then
        opts.ensure_installed = {}
      else
        opts.ensure_installed = require("config.mason").packages()
      end
    end,
  },
}
