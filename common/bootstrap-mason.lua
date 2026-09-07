local mason_plugin = vim.env.DOTFILES_MASON_PLUGIN
local package_list = vim.env.DOTFILES_MASON_PACKAGES

assert(
  mason_plugin and vim.fn.isdirectory(mason_plugin) == 1,
  "mason.nvim is not installed: " .. (mason_plugin or "")
)
assert(package_list and package_list ~= "", "DOTFILES_MASON_PACKAGES is empty")

vim.opt.runtimepath:prepend(mason_plugin)

require("mason").setup({
  registries = {
    "github:mason-org/mason-registry",
    "github:Crashdummyy/mason-registry",
  },
})

-- MasonInstall blocks in headless mode, exits non-zero for an invalid package
-- or failed install, and refreshes the configured registries before installing.
require("mason.api.command").MasonInstall(vim.split(package_list, " ", { trimempty = true }))
