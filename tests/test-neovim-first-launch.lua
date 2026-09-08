local calls = {}

_G.LazyVim = {
  get_pkg_path = function(package, path, opts)
    table.insert(calls, { package = package, path = path, opts = opts })
    return "/not-installed-yet" .. path
  end,
}

local plugins = dofile("nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua")
assert(#calls == 1, "expected exactly one Mason package path lookup")
assert(calls[1].package == "netcoredbg", "expected netcoredbg package lookup")
assert(calls[1].path == "/libexec/netcoredbg/netcoredbg", "unexpected netcoredbg path")
assert(calls[1].opts.warn == false, "first-launch missing package warning must be disabled")

local easy_dotnet
for _, plugin in ipairs(plugins) do
  if plugin[1] == "GustavEikaas/easy-dotnet.nvim" then
    easy_dotnet = plugin
    break
  end
end

assert(easy_dotnet, "easy-dotnet plugin spec not found")
assert(easy_dotnet.opts.debugger.bin_path == "/not-installed-yet/libexec/netcoredbg/netcoredbg")

local inventory_path = "nvim-lazyvim/.config/nvim/mason-packages.txt"
local mason_config = dofile("nvim-lazyvim/.config/nvim/lua/config/mason.lua")
local packages = mason_config.packages(inventory_path)
assert(#packages == 16, "expected the complete Mason package inventory")
assert(vim.tbl_contains(packages, "debugpy"), "debugpy is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "marksman"), "marksman is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "roslyn"), "roslyn is missing from the Mason inventory")
assert(not vim.tbl_contains(packages, "ocaml-lsp"), "OCaml LSP must remain opam-owned")

local markdown_plugins = dofile("nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua")
local markdown_mason
local markdown_lint
local markdown_table
for _, plugin in ipairs(markdown_plugins) do
  if plugin[1] == "mason-org/mason.nvim" then
    markdown_mason = plugin
  elseif plugin[1] == "mfussenegger/nvim-lint" then
    markdown_lint = plugin
  elseif plugin[1] == "SCJangra/table-nvim" then
    markdown_table = plugin
  end
end

assert(markdown_mason and markdown_lint and markdown_table, "Markdown plugin ownership specs are incomplete")
local markdown_mason_opts = { ensure_installed = { "markdown-toc", "marksman", "markdownlint-cli2" } }
markdown_mason.opts(nil, markdown_mason_opts)
assert(vim.deep_equal(markdown_mason_opts.ensure_installed, { "marksman" }), "project Markdown tools leaked into Mason")

local markdown_lint_opts = { linters_by_ft = { markdown = { "markdownlint-cli2" }, yaml = { "yamllint" } } }
markdown_lint.opts(nil, markdown_lint_opts)
assert(markdown_lint_opts.linters_by_ft.markdown == nil, "global Markdown style linting remains enabled")
assert(markdown_lint_opts.linters_by_ft.yaml[1] == "yamllint", "unrelated lint configuration was changed")
assert(markdown_table.opts.mappings.next ~= "<Tab>", "table navigation overrides LazyVim Tab completion")

local previous_mason_module = package.loaded["config.mason"]
local previous_bootstrap = vim.env.DOTFILES_MASON_BOOTSTRAP
package.loaded["config.mason"] = {
  packages = function()
    return packages
  end,
}

vim.env.DOTFILES_MASON_BOOTSTRAP = nil
local mason_plugins = dofile("nvim-lazyvim/.config/nvim/lua/plugins/mason.lua")
local mason_opts = { ensure_installed = { "stylua" } }
mason_plugins[1].opts(nil, mason_opts)
assert(#mason_opts.ensure_installed == #packages, "Mason ensure_installed does not match the inventory")
for _, package in ipairs(packages) do
  local count = 0
  for _, installed in ipairs(mason_opts.ensure_installed) do
    count = count + (installed == package and 1 or 0)
  end
  assert(count == 1, "Mason package is missing or duplicated: " .. package)
end

vim.env.DOTFILES_MASON_BOOTSTRAP = "1"
mason_opts = { ensure_installed = { "stylua", "roslyn" } }
mason_plugins[1].opts(nil, mason_opts)
assert(#mason_opts.ensure_installed == 0, "bootstrap must suppress Mason's asynchronous ensure loop")

vim.env.DOTFILES_MASON_BOOTSTRAP = previous_bootstrap
package.loaded["config.mason"] = previous_mason_module

local previous_mason = package.loaded.mason
local previous_mason_command = package.loaded["mason.api.command"]
local previous_mason_plugin = vim.env.DOTFILES_MASON_PLUGIN
local previous_mason_packages = vim.env.DOTFILES_MASON_PACKAGES
local mason_setup_opts
local bootstrap_packages

package.loaded.mason = {
  setup = function(opts)
    mason_setup_opts = opts
  end,
}
package.loaded["mason.api.command"] = {
  MasonInstall = function(requested_packages)
    bootstrap_packages = requested_packages
  end,
}
vim.env.DOTFILES_MASON_PLUGIN = vim.fn.getcwd()
vim.env.DOTFILES_MASON_PACKAGES = table.concat(packages, " ")

dofile("common/bootstrap-mason.lua")

assert(#bootstrap_packages == #packages, "headless bootstrap package count does not match inventory")
for index, package in ipairs(packages) do
  assert(bootstrap_packages[index] == package, "headless bootstrap package mismatch: " .. package)
end
assert(
  vim.tbl_contains(mason_setup_opts.registries, "github:Crashdummyy/mason-registry"),
  "headless bootstrap omitted the custom .NET Mason registry"
)

vim.env.DOTFILES_MASON_PLUGIN = previous_mason_plugin
vim.env.DOTFILES_MASON_PACKAGES = previous_mason_packages
package.loaded.mason = previous_mason
package.loaded["mason.api.command"] = previous_mason_command
