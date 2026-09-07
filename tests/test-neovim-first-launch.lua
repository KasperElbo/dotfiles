local calls = {}

_G.LazyVim = {
  get_pkg_path = function(package, path, opts)
    table.insert(calls, { package = package, path = path, opts = opts })
    return "/not-installed-yet" .. path
  end,
}

local plugins = dofile("nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua")
assert(#calls == 1, "expected exactly one Mason package path lookup")
assert(calls[1].package == "netcoredbg", "expected netcoredbg package lookup")
assert(calls[1].path == "/libexec/netcoredbg/netcoredbg", "unexpected netcoredbg path")
assert(calls[1].opts.warn == false, "first-launch missing package warning must be disabled")

local easy_dotnet
for _, plugin in ipairs(plugins) do
  if plugin[1] == "GustavEikaas/easy-dotnet.nvim" then
    easy_dotnet = plugin
    break
  end
end

assert(easy_dotnet, "easy-dotnet plugin spec not found")
assert(easy_dotnet.opts.debugger.bin_path == "/not-installed-yet/libexec/netcoredbg/netcoredbg")
