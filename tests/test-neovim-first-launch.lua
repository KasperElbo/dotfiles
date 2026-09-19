local plugins = dofile("nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua")

local easy_dotnet
for _, plugin in ipairs(plugins) do
  if plugin[1] == "GustavEikaas/easy-dotnet.nvim" then
    easy_dotnet = plugin
    break
  end
end

assert(easy_dotnet, "easy-dotnet plugin spec not found")
assert(easy_dotnet.opts.debugger.engine == "netcoredbg")
assert(easy_dotnet.opts.debugger.auto_register_dap == true)
assert(easy_dotnet.opts.debugger.bin_path == nil)

local inventory_path = "nvim-lazyvim/.config/nvim/mason-packages.txt"
local mason_config = dofile("nvim-lazyvim/.config/nvim/lua/config/mason.lua")
local packages = mason_config.packages(inventory_path)
assert(#packages == 17, "expected the complete Mason package inventory")
assert(vim.tbl_contains(packages, "debugpy"), "debugpy is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "marksman"), "marksman is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "prettier"), "prettier is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "roslyn"), "roslyn is missing from the Mason inventory")
assert(vim.tbl_contains(packages, "tree-sitter-cli"), "tree-sitter-cli is missing from the Mason inventory")
assert(not vim.tbl_contains(packages, "ocaml-lsp"), "OCaml LSP must remain opam-owned")

local previous_profile = vim.env.DOTFILES_NVIM_PROFILE
package.path = "nvim-lazyvim/.config/nvim/lua/?.lua;nvim-lazyvim/.config/nvim/lua/?/init.lua;" .. package.path

-- The set the reduced profile is supposed to carry, stated once. Naming it
-- here rather than deriving it from the Parrot profile is the point: a
-- workstation extra that displaced one of these would still leave three.
local reduced_extras = {
  "lazyvim.plugins.extras.dap.core",
  "lazyvim.plugins.extras.lang.python",
  "lazyvim.plugins.extras.test.core",
}

-- What must not leak is read out of the workstation profile rather than
-- listed, so an extra added there is covered without editing this test.
vim.env.DOTFILES_NVIM_PROFILE = "workstation"
package.loaded["config.profile"] = nil
local workstation_extras = require("config.profile").current().extras
local workstation_only = {}
for _, extra in ipairs(workstation_extras) do
  if not vim.tbl_contains(reduced_extras, extra) then
    table.insert(workstation_only, extra)
  end
end

vim.env.DOTFILES_NVIM_PROFILE = "parrot-ctf"
package.loaded["config.profile"] = nil
local profile = require("config.profile")
assert(profile.name() == "parrot-ctf", "explicit Parrot Neovim profile was not selected")
assert(profile.current().checker_enabled == false, "Parrot profile must not check for updates at startup")
assert(profile.current().plugins == "ctf_plugins", "Parrot profile loaded workstation plugin overrides")

local parrot_extras = profile.current().extras

-- Before concluding that nothing leaked: there has to be something to leak.
-- If the two profiles ever declared the same extras, the loop below would
-- compare nothing and pass, which is how the check it replaces went quiet.
assert(
  #workstation_only > 0,
  "the workstation profile declares no extra the reduced set lacks, so the leak check compares nothing"
)
for _, extra in ipairs(workstation_only) do
  assert(
    not vim.tbl_contains(parrot_extras, extra),
    "workstation extra leaked into Parrot profile: " .. extra
  )
end

-- The other direction, which the count alone does not give: a leak that
-- displaced one of the three would still leave three.
assert(
  #parrot_extras == #reduced_extras,
  "Parrot profile should contain only the reduced extra set"
)
for _, extra in ipairs(reduced_extras) do
  assert(
    vim.tbl_contains(parrot_extras, extra),
    "the reduced Parrot extra set lost " .. extra
  )
end

vim.env.DOTFILES_NVIM_PROFILE = previous_profile
package.loaded["config.profile"] = nil

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
