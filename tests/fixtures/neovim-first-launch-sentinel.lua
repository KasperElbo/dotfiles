-- Deliberate failure fixture for the Neovim Lua test harness.
--
-- The shell harness runs this through exactly the same invocation as the real
-- first-launch test. A failed Lua assertion must therefore produce a nonzero
-- Neovim exit status, and the captured output must name this file and the
-- assertion message. No trailing quit command may overwrite that status.
local mason = dofile("nvim-lazyvim/.config/nvim/lua/config/mason.lua")
local packages = mason.packages("nvim-lazyvim/.config/nvim/mason-packages.txt")

assert(
  vim.tbl_contains(packages, "dotfiles-sentinel-package"),
  "dotfiles first-launch sentinel: intentional assertion failure"
)
