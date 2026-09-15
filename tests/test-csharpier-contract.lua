-- Contract for the project-local CSharpier formatter.
--
-- Run through `nvim -l` so a failed assertion becomes a nonzero exit status.
--
-- DOTFILES_CSHARPIER_FIXTURE names a disposable .NET project that declares
-- CSharpier in a local tool manifest. When DOTFILES_CSHARPIER_ARGV_OUT is set,
-- the resolved Conform invocation is written there so the shell harness runs
-- exactly the argv this configuration produces instead of a copy of it.

package.path = "nvim-lazyvim/.config/nvim/lua/?.lua;nvim-lazyvim/.config/nvim/lua/?/init.lua;"
  .. package.path

local fixture = assert(vim.env.DOTFILES_CSHARPIER_FIXTURE, "fixture root is required")
local csharpier = require("config.csharpier")

-- Manifest resolution must follow the edited buffer, not Neovim's own working
-- directory, or a project opened from elsewhere resolves the wrong tool.
assert(
  csharpier.manifest_root(fixture .. "/src/BadlyFormatted.cs") == fixture,
  "manifest root was not resolved from the edited file"
)
assert(
  csharpier.manifest_root(fixture .. "/src") == fixture,
  "manifest root was not resolved from a directory"
)
assert(
  csharpier.manifest_root(fixture) == fixture,
  "manifest root was not resolved from the project root itself"
)

local unrelated = assert(vim.env.DOTFILES_CSHARPIER_UNRELATED, "unrelated root is required")
assert(
  csharpier.manifest_root(unrelated .. "/Program.cs") == nil,
  "a project without a tool manifest must not resolve a CSharpier root"
)

local formatter = csharpier.formatter()

-- `dotnet` is the only command this formatter can run: Conform's built-in
-- fallback to a bare `csharpier` executable must not survive the override.
assert(formatter.inherit == false, "the ambient built-in fallback is still inherited")
assert(formatter.command == "dotnet", "CSharpier is not invoked through the .NET SDK")
assert(formatter.stdin == true, "CSharpier must format the buffer over stdin")
assert(formatter.require_cwd == true, "a missing tool manifest must disable the formatter")
assert(
  vim.deep_equal(formatter.args, { "csharpier", "format", "--stdin-path", "$FILENAME" }),
  "unexpected CSharpier invocation: " .. vim.inspect(formatter.args)
)
assert(
  formatter.cwd(formatter, { dirname = fixture .. "/src" }) == fixture,
  "the formatter does not run in the project that owns CSharpier"
)
assert(
  formatter.cwd(formatter, { dirname = unrelated }) == nil,
  "the formatter resolved a working directory without a tool manifest"
)

-- The Conform mapping and the formatter definition must agree, so `cs` cannot
-- silently resolve to the built-in definition again.
local formatting = dofile("nvim-lazyvim/.config/nvim/lua/plugins/formatting.lua")
local conform
for _, plugin in ipairs(formatting) do
  if plugin[1] == "stevearc/conform.nvim" then
    conform = plugin
  end
end
assert(conform, "the Conform plugin spec is missing")
assert(
  vim.deep_equal(conform.opts.formatters_by_ft.cs, { "csharpier" }),
  "C# files are not mapped to CSharpier"
)
assert(conform.opts.formatters.csharpier, "the CSharpier override is not registered with Conform")
assert(
  conform.opts.formatters.csharpier.command == "dotnet",
  "the registered CSharpier formatter does not use the .NET SDK"
)

local argv_out = vim.env.DOTFILES_CSHARPIER_ARGV_OUT
if argv_out and argv_out ~= "" then
  local resolved = { formatter.command }
  vim.list_extend(resolved, formatter.args)
  assert(vim.fn.writefile(resolved, argv_out) == 0, "could not record the resolved argv")
end
