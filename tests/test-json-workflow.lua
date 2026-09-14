-- Ownership contract for the JSON/JSONC editing workflow.
--
-- Run through `nvim -l` so a failed assertion becomes a nonzero exit status.
-- This asserts what the repository declares; tests/json-workflow.lua asserts
-- what an installed Neovim actually does.

package.path = "nvim-lazyvim/.config/nvim/lua/?.lua;nvim-lazyvim/.config/nvim/lua/?/init.lua;"
  .. package.path

local config_root = "nvim-lazyvim/.config/nvim"

local function profile_for(name)
  vim.env.DOTFILES_NVIM_PROFILE = name
  package.loaded["config.profile"] = nil
  local profile = require("config.profile")
  assert(profile.name() == name, "profile " .. name .. " was not selected")
  return profile.current()
end

local function packages_for(inventory)
  package.loaded["config.mason"] = nil
  return require("config.mason").packages(config_root .. "/" .. inventory)
end

local previous_profile = vim.env.DOTFILES_NVIM_PROFILE

-- The workstation profile owns the complete JSON workflow: language support
-- from the JSON extra, and the formatter from LazyVim's supported Prettier
-- integration rather than a hand-rolled copy of it.
local workstation = profile_for("workstation")
for _, extra in ipairs({
  "lazyvim.plugins.extras.lang.json",
  "lazyvim.plugins.extras.formatting.prettier",
}) do
  assert(
    vim.tbl_contains(workstation.extras, extra),
    "the workstation profile does not enable " .. extra
  )
end

local workstation_packages = packages_for(workstation.mason_inventory)
for _, package in ipairs({ "json-lsp", "prettier" }) do
  assert(
    vim.tbl_contains(workstation_packages, package),
    package .. " is missing from the tracked Mason inventory, so a clean "
      .. "bootstrap would not install it"
  )
end

-- The reduced CTF profile deliberately does not carry the JSON workflow. This
-- is an explicit exclusion, not an oversight: asserting it keeps a later
-- "parity" change from quietly enlarging the profile.
local parrot = profile_for("parrot-ctf")
for _, extra in ipairs({
  "lazyvim.plugins.extras.lang.json",
  "lazyvim.plugins.extras.formatting.prettier",
}) do
  assert(
    not vim.tbl_contains(parrot.extras, extra),
    "a workstation JSON extra leaked into the reduced Parrot profile: " .. extra
  )
end

local parrot_packages = packages_for(parrot.mason_inventory)
for _, package in ipairs({ "json-lsp", "prettier" }) do
  assert(
    not vim.tbl_contains(parrot_packages, package),
    "a workstation JSON tool leaked into the reduced Parrot inventory: " .. package
  )
end

vim.env.DOTFILES_NVIM_PROFILE = previous_profile
package.loaded["config.profile"] = nil

-- LazyVim's Prettier extra already maps every filetype Prettier supports, so a
-- second local mapping would be a competing source of truth for the same
-- filetypes. Angular's separate template filetype is not one of them.
local formatting = dofile(config_root .. "/lua/plugins/formatting.lua")
local conform
for _, plugin in ipairs(formatting) do
  if plugin[1] == "stevearc/conform.nvim" then
    conform = plugin
  end
end
assert(conform, "the Conform plugin spec is missing")
for _, filetype in ipairs({ "json", "jsonc", "yaml", "markdown", "typescript" }) do
  assert(
    conform.opts.formatters_by_ft[filetype] == nil,
    "the Prettier extra already owns the " .. filetype .. " mapping"
  )
end
assert(
  vim.deep_equal(conform.opts.formatters_by_ft.htmlangular, { "prettier" }),
  "the Angular template filetype lost its Prettier mapping"
)
