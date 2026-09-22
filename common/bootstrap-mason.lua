local mason_plugin = vim.env.DOTFILES_MASON_PLUGIN
local package_list = vim.env.DOTFILES_MASON_PACKAGES or ""
local repair_list = vim.env.DOTFILES_MASON_REPAIR_PACKAGES or ""

assert(
  mason_plugin and vim.fn.isdirectory(mason_plugin) == 1,
  "mason.nvim is not installed: " .. (mason_plugin or "")
)

local fresh_packages = vim.split(package_list, " ", { trimempty = true })
local repair_packages = vim.split(repair_list, " ", { trimempty = true })
assert(
  #fresh_packages > 0 or #repair_packages > 0,
  "DOTFILES_MASON_PACKAGES and DOTFILES_MASON_REPAIR_PACKAGES are both empty"
)

vim.opt.runtimepath:prepend(mason_plugin)

require("mason").setup({
  registries = {
    -- Every LSP server and debug adapter Mason installs is resolved through
    -- these two lists, so each is a trust root of its own.
    -- network-source: mason-registry
    "github:mason-org/mason-registry",
    -- network-source: mason-registry-crashdummyy
    "github:Crashdummyy/mason-registry",
  },
})

-- MasonInstall blocks in headless mode, exits non-zero for an invalid package
-- or failed install, and refreshes the configured registries before installing.
-- Entries may carry a "package@version" pin from common/mason-package-versions.txt;
-- Mason resolves those against the registry entry instead of its latest version.
-- It only quits Neovim on failure, so the two calls below run in sequence.
local MasonInstall = require("mason.api.command").MasonInstall

-- Repairs are the packages common/install-neovim-tools.sh found already
-- present but not completely installed, or installed at the wrong pinned
-- version. They need force: without it Mason refuses to relink over the links
-- the previous attempt left behind, and refuses the package outright while
-- that attempt's staging lock file is still there.
if #repair_packages > 0 then
  MasonInstall(repair_packages, { force = true })
end

if #fresh_packages > 0 then
  MasonInstall(fresh_packages)
end
