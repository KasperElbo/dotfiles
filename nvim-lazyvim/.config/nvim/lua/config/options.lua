-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
-- Neovim remote-plugin hosts managed by mise.
local node_host = vim.fn.exepath("neovim-node-host")
if node_host ~= "" then
  vim.g.node_host_prog = node_host
end

local python_host = vim.fn.exepath("pynvim-python")
if python_host ~= "" then
  vim.g.python3_host_prog = python_host
end

vim.g.lazyvim_eslint_auto_format = false

vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
