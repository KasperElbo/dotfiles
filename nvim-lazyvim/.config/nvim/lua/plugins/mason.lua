return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    opts = function(_, opts)
      -- The installer invokes :MasonInstall itself and waits for it. Disable
      -- Mason's asynchronous ensure loop in that process to avoid racing it.
      if vim.env.DOTFILES_MASON_BOOTSTRAP == "1" then
        opts.ensure_installed = {}
        return
      end

      opts.ensure_installed = opts.ensure_installed or {}
      for _, package in ipairs(require("config.mason").packages()) do
        if not vim.tbl_contains(opts.ensure_installed, package) then
          table.insert(opts.ensure_installed, package)
        end
      end
    end,
  },
}
