local function catppuccin_flavour()
  local config_home = vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")

  local path = config_home .. "/dotfiles/theme"
  local file = io.open(path, "r")

  if not file then
    return "macchiato"
  end

  local flavour = vim.trim(file:read("*l") or "")
  file:close()

  local valid = {
    latte = true,
    frappe = true,
    macchiato = true,
    mocha = true,
  }

  return valid[flavour] and flavour or "macchiato"
end

local function colorscheme()
  return "catppuccin-" .. catppuccin_flavour()
end

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,

    -- The `theme` command writes the machine-local flavour while Neovim is
    -- already running, so open windows pick it up on the next focus.
    --
    -- This belongs here rather than on the "LazyVim/LazyVim" spec below,
    -- where it used to live: both platform overlays
    -- (platforms/macos/.../plugins/macos.lua and
    -- platforms/fedora-wsl/.../plugins/wsl.lua) declare `init` on that spec
    -- for their launch settings, and lazy.nvim merges only `opts`,
    -- `dependencies`, `cmd`, `event`, `ft` and `keys` -- every other key,
    -- `init` among them, is overridden by the last fragment imported. No
    -- fragment competes for this spec's `init`, and
    -- scripts/validate-neovim-plugin-specs.py fails the lint if one ever does.
    init = function()
      vim.api.nvim_create_autocmd("FocusGained", {
        callback = function()
          local wanted = colorscheme()

          if vim.g.colors_name ~= wanted then
            vim.cmd.colorscheme(wanted)
          end
        end,
      })
    end,
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = function()
        vim.cmd.colorscheme(colorscheme())
      end,
    },
  },
}
