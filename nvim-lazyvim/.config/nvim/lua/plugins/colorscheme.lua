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
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = function()
        vim.cmd.colorscheme(colorscheme())
      end,
    },

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
}
