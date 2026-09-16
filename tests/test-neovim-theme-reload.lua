-- The documented theme reload, proven through lazy.nvim's own spec resolution
-- with one platform overlay stowed alongside the shared fragments.
--
-- `theme` writes the machine-local flavour while Neovim is running, and
-- docs/workflows/theming.md and docs/troubleshooting.md both tell the user that
-- refocusing the window picks it up. That promise is only kept if the
-- `FocusGained` autocmd survives fragment merging: lazy.nvim overrides every
-- key outside `opts`, `dependencies`, `cmd`, `event`, `ft` and `keys`, so a
-- fragment that both the shared config and an overlay declare has exactly one
-- survivor (issue #248, RA-36).
--
-- The caller stows a merged config directory, points XDG_CONFIG_HOME at a
-- theme state file, and names the overlay under test.

local config = assert(vim.env.DOTFILES_TEST_NVIM_CONFIG, "DOTFILES_TEST_NVIM_CONFIG is unset")
local lazypath = assert(vim.env.DOTFILES_TEST_LAZY, "DOTFILES_TEST_LAZY is unset")
local scratch = assert(vim.env.DOTFILES_TEST_SCRATCH, "DOTFILES_TEST_SCRATCH is unset")
local overlay = assert(vim.env.DOTFILES_TEST_OVERLAY, "DOTFILES_TEST_OVERLAY is unset")
local flavour = assert(vim.env.DOTFILES_TEST_FLAVOUR, "DOTFILES_TEST_FLAVOUR is unset")

vim.opt.rtp:prepend(lazypath)
vim.opt.rtp:prepend(config)
package.path = config .. "/lua/?.lua;" .. config .. "/lua/?/init.lua;" .. package.path

-- `nvim -l` starts with plugin loading disabled, which lazy.nvim honours by
-- returning from setup without resolving anything.
vim.go.loadplugins = true

require("lazy").setup({
  spec = { { import = "plugins" } },
  root = scratch .. "/plugins",
  lockfile = scratch .. "/lazy-lock.json",
  state = scratch .. "/state.json",
  -- Nothing is installed and nothing may be: this resolves the spec set the
  -- machine would have, it does not build one.
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
  performance = { rtp = { reset = false } },
})

-- The overlay really is part of the resolved set. Without this, every
-- assertion below would pass just as happily against the shared config alone.
local overlay_evidence = {
  ["nvim-macos"] = { key = "vimtex_view_general_viewer", value = "open" },
  ["nvim-wsl"] = { key = "vimtex_view_general_viewer", value = "wsl-open" },
}

local evidence = assert(overlay_evidence[overlay], "unknown overlay: " .. overlay)
assert(
  vim.g[evidence.key] == evidence.value,
  ("the %s overlay's own init did not run: vim.g.%s is %s, expected %s"):format(
    overlay,
    evidence.key,
    vim.inspect(vim.g[evidence.key]),
    evidence.value
  )
)

local plugins = require("lazy.core.config").plugins
local lazyvim = assert(plugins.LazyVim, "the LazyVim spec did not resolve")
assert(
  type(lazyvim.opts) == "table" or type(lazyvim.opts) == "function",
  "the shared LazyVim opts were lost while resolving the " .. overlay .. " overlay"
)

local focus_autocmds = vim.api.nvim_get_autocmds({ event = "FocusGained" })
assert(
  #focus_autocmds > 0,
  "no FocusGained autocmd survived spec resolution with the "
    .. overlay
    .. " overlay, so switching flavour leaves open windows on the old colorscheme"
)

-- Capture the colorscheme the reload asks for. No plugin is installed here, so
-- letting the real command run would only prove that catppuccin is missing.
local applied
local original_cmd = vim.cmd
vim.cmd = setmetatable({}, {
  __index = function(_, key)
    if key == "colorscheme" then
      return function(name)
        applied = name
      end
    end
    return original_cmd[key]
  end,
  __call = function(_, ...)
    return original_cmd(...)
  end,
})

vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })

vim.cmd = original_cmd

assert(
  applied == "catppuccin-" .. flavour,
  ("refocusing did not reload the machine-local flavour with the %s overlay: applied %s, expected %s"):format(
    overlay,
    vim.inspect(applied),
    "catppuccin-" .. flavour
  )
)
