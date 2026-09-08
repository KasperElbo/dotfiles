return {
  {
    "LazyVim/LazyVim",
    init = function()
      -- Keep Windows process discovery out of the shared editor config. This
      -- adapter supports Neovim's gx/vim.ui.open and markdown-preview.nvim
      -- after the Windows PATH has deliberately been removed from WSL.
      vim.ui.open = function(target)
        return vim.system({ "wsl-open", target }, { detach = true })
      end

      vim.g.mkdp_browserfunc = "DotfilesMarkdownPreviewOpen"
      vim.cmd([[
        function! DotfilesMarkdownPreviewOpen(url) abort
          call jobstart(['wsl-open', a:url], {'detach': v:true})
        endfunction
      ]])
    end,
    opts = function()
      if vim.fn.has("wsl") ~= 1 then
        return
      end

      vim.g.clipboard = {
        name = "Windows clipboard through WSL interop",
        copy = {
          ["+"] = { "wsl-copy" },
          ["*"] = { "wsl-copy" },
        },
        paste = {
          ["+"] = { "wsl-paste" },
          ["*"] = { "wsl-paste" },
        },
        cache_enabled = 0,
      }
    end,
  },
}
