-- Project-local CSharpier ownership.
--
-- CSharpier is declared by the .NET repository in its local tool manifest, so
-- the editor must invoke it through the SDK's local-tool entry point. Conform's
-- built-in definition probes `dotnet csharpier` once per Neovim process, in
-- Neovim's own working directory, and falls back to a bare `csharpier` on PATH
-- when that probe fails. Both halves break the ownership contract: the probe
-- answers for the wrong directory when Neovim was started outside the project,
-- and the fallback formats a project with an ambient executable it does not
-- declare.
--
-- This module resolves the manifest from the edited buffer instead, and the
-- Conform definition below never names a bare `csharpier` command at all.

local M = {}

-- `dotnet new tool-manifest` writes `.config/dotnet-tools.json`; the SDK also
-- accepts a manifest placed directly in a directory.
M.manifests = { ".config/dotnet-tools.json", "dotnet-tools.json" }

--- Nearest directory at or above `start` that declares a .NET local tool
--- manifest.
---@param start string|nil file or directory to search upward from
---@return string|nil
function M.manifest_root(start)
  local directory = vim.fs.normalize(start or "")
  if directory == "" then
    return nil
  end
  if vim.fn.isdirectory(directory) == 0 then
    directory = vim.fs.dirname(directory)
  end

  while directory and directory ~= "" do
    for _, manifest in ipairs(M.manifests) do
      if vim.uv.fs_stat(directory .. "/" .. manifest) then
        return directory
      end
    end

    local parent = vim.fs.dirname(directory)
    if not parent or parent == directory then
      return nil
    end
    directory = parent
  end

  return nil
end

--- Conform definition for the project-owned CSharpier.
---
--- `inherit = false` keeps the built-in's ambient fallback out of the resolved
--- configuration, so the only command this formatter can ever run is the .NET
--- SDK. `require_cwd` then keeps the formatter unavailable outside a project
--- that declares CSharpier, rather than substituting a global executable.
---
--- When the manifest exists but the tool has not been restored, `dotnet` exits
--- non-zero with `Run "dotnet tool restore" to make the "csharpier" command
--- available.`, which Conform surfaces unchanged.
---@return table
function M.formatter()
  return {
    inherit = false,
    command = "dotnet",
    args = { "csharpier", "format", "--stdin-path", "$FILENAME" },
    stdin = true,
    require_cwd = true,
    cwd = function(_, ctx)
      return M.manifest_root(ctx.dirname or ctx.filename)
    end,
  }
end

return M
