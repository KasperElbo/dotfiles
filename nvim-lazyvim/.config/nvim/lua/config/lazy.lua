-- Verification starts this configuration to prove it loads, and must leave the
-- machine exactly as it found it. In that mode a missing lazy.nvim, or a
-- missing plugin, is the answer -- not a repair. Without this, the verifier
-- clones what is absent and then credits the state it just created: on a
-- machine with no plugin tree the Fedora check installed the whole spec and
-- reported a pass, and because stdpath("config") is the stowed symlink, Lazy
-- rewrote the tracked lazy-lock.json in the checkout to branch tips.
--
-- The shell verifier still owns the verdict. This only makes the startup it
-- runs observational, so common/lib/verify.sh can judge a machine that was
-- never touched.
local verify_only = vim.env.DOTFILES_NVIM_VERIFY == "1"

-- Headless means nobody is at the keyboard, so there is nothing to prompt.
local interactive = #vim.api.nvim_list_uis() > 0

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  if verify_only then
    -- Named, immediate, and silent about repair: the verifier reports the
    -- absence rather than filling it in.
    io.stderr:write("lazy.nvim is not installed: " .. lazypath .. "\n")
    os.exit(1)
  end

  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  -- network-source: lazy-nvim
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      interactive and { "\nPress any key to exit..." } or { "\n" },
    }, true, {})
    -- getchar() blocks forever without a UI -- even with stdin on /dev/null --
    -- so a headless clone failure used to hang until something killed it.
    if interactive then
      vim.fn.getchar()
    end
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

local profile = require("config.profile")
if profile.name() == "parrot-ctf" then
  -- basedpyright is distributed as a self-contained Python package through
  -- Mason, so the reduced guest profile does not need a mise-managed Node.
  vim.g.lazyvim_python_lsp = "basedpyright"
end

require("lazy").setup({
  spec = profile.spec(),
  lockfile = profile.lockfile(),
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  -- `missing` is the one that matters: with it on, simply starting Neovim
  -- installs every plugin the spec names and is not on disk, which is how
  -- verification came to repair the tree it was inspecting.
  install = { missing = not verify_only, colorscheme = { "tokyonight", "habamax" } },
  -- Generated help tags and README copies are writes too, and under a
  -- disposable XDG view they follow symlinks back into the real plugin
  -- directories.
  readme = { enabled = not verify_only },
  change_detection = { enabled = not verify_only },
  checker = {
    enabled = not verify_only and profile.current().checker_enabled,
    notify = false, -- notify on update
  }, -- automatically check for plugin updates
  rocks = {
    enabled = false,
  },
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
