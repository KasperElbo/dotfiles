local M = {}

local profiles = {
  workstation = {
    checker_enabled = true,
    lockfile = "lazy-lock.json",
    extras = {
      "lazyvim.plugins.extras.dap.core",
      "lazyvim.plugins.extras.lang.angular",
      "lazyvim.plugins.extras.lang.json",
      "lazyvim.plugins.extras.lang.markdown",
      "lazyvim.plugins.extras.lang.python",
      "lazyvim.plugins.extras.lang.tex",
      "lazyvim.plugins.extras.lang.yaml",
      "lazyvim.plugins.extras.linting.eslint",
      "lazyvim.plugins.extras.test.core",
    },
    plugins = "plugins",
    mason_inventory = "mason-packages.txt",
  },
  ["parrot-ctf"] = {
    checker_enabled = false,
    lockfile = "profiles/parrot-ctf/lazy-lock.json",
    extras = {
      "lazyvim.plugins.extras.dap.core",
      "lazyvim.plugins.extras.lang.python",
      "lazyvim.plugins.extras.test.core",
    },
    plugins = "ctf_plugins",
    mason_inventory = "profiles/parrot-ctf/mason-packages.txt",
  },
}

local function profile_marker()
  local config_home = vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")
  local marker = io.open(config_home .. "/dotfiles/neovim-profile", "r")
  if not marker then
    return nil
  end

  local value = vim.trim(marker:read("*l") or "")
  marker:close()
  return value ~= "" and value or nil
end

function M.name()
  local name = vim.env.DOTFILES_NVIM_PROFILE or profile_marker() or "workstation"
  assert(profiles[name], "Unsupported dotfiles Neovim profile: " .. name)
  return name
end

function M.current()
  return profiles[M.name()]
end

function M.spec()
  local selected = M.current()
  local spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
  }

  for _, extra in ipairs(selected.extras) do
    table.insert(spec, { import = extra })
  end

  table.insert(spec, { import = selected.plugins })
  return spec
end

function M.mason_inventory()
  return vim.fn.stdpath("config") .. "/" .. M.current().mason_inventory
end

function M.lockfile()
  return vim.fn.stdpath("config") .. "/" .. M.current().lockfile
end

return M
