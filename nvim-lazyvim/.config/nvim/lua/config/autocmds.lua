-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- LazyVim applies these writing defaults to Markdown. MDX uses a distinct
-- filetype, so keep its editing behaviour consistent with regular Markdown.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown.mdx",
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.spell = true
  end,
})
