return {
  {
    "LazyVim/LazyVim",
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
