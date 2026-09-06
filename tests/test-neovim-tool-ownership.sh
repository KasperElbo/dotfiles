#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lazyvim_config="$repo_root/nvim-lazyvim/.config/nvim"

fail() {
  printf 'Neovim ownership test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local value="$2"

  grep -Fq -- "$value" "$file" ||
    fail "$file does not contain: $value"
}

[[ ! -e "$lazyvim_config/lua/plugins/example.lua" ]] ||
  fail "unused LazyVim example.lua is still tracked"

lazyvim_extras=(
  lazyvim.plugins.extras.dap.core
  lazyvim.plugins.extras.lang.angular
  lazyvim.plugins.extras.lang.json
  lazyvim.plugins.extras.lang.python
  lazyvim.plugins.extras.lang.tex
  lazyvim.plugins.extras.lang.yaml
  lazyvim.plugins.extras.linting.eslint
  lazyvim.plugins.extras.test.core
)

for extra in "${lazyvim_extras[@]}"; do
  assert_contains "$lazyvim_config/lazyvim.json" "\"$extra\""
done

dotnet_config="$lazyvim_config/lua/plugins/dotnet.lua"
assert_contains "$dotnet_config" '"roslyn"'
assert_contains "$dotnet_config" '"netcoredbg"'
assert_contains "$dotnet_config" 'lsp = {'
assert_contains "$dotnet_config" 'enabled = false'
assert_contains "$dotnet_config" \
  'bin_path = LazyVim.get_pkg_path("netcoredbg", "/libexec/netcoredbg/netcoredbg")'
assert_contains "$dotnet_config" 'auto_register_dap = true'
assert_contains "$dotnet_config" '"jay-babu/mason-nvim-dap.nvim"'
assert_contains "$dotnet_config" 'coreclr = function() end'

formatting_config="$lazyvim_config/lua/plugins/formatting.lua"
assert_contains "$formatting_config" 'cs = { "csharpier" }'
assert_contains "$formatting_config" 'typescript = { "prettier" }'
assert_contains "$formatting_config" 'htmlangular = { "prettier" }'
assert_contains "$formatting_config" 'python = { "ruff_format" }'
assert_contains "$lazyvim_config/lua/config/options.lua" \
  'vim.g.lazyvim_eslint_auto_format = false'

assert_contains "$repo_root/platforms/fedora/scripts/install-system.sh" '  ShellCheck'

mason_inventory="$(
  sed -n '/^mason_packages=(/,/^)/p' \
    "$repo_root/platforms/fedora/scripts/verify.sh"
)"

expected_mason_packages=(
  angular-language-server
  debugpy
  eslint-lsp
  js-debug-adapter
  json-lsp
  lua-language-server
  netcoredbg
  pyright
  roslyn
  ruff
  shfmt
  stylua
  texlab
  vtsls
  yaml-language-server
)

for package in "${expected_mason_packages[@]}"; do
  grep -Fqx "  $package" <<<"$mason_inventory" ||
    fail "expected Mason package is not verified: $package"
done

project_tools=(
  csharpier
  dotnet-ef
  eslint
  prettier
  pytest
  trx2junit
  typescript
)

for tool in "${project_tools[@]}"; do
  if grep -Fiq -- "$tool" "$repo_root/mise/.config/mise/config.toml"; then
    fail "project-local tool is declared through mise: $tool"
  fi

  if grep -Fqx "  $tool" <<<"$mason_inventory"; then
    fail "project-local tool is declared through Mason: $tool"
  fi
done

angular_fixture="$repo_root/tests/fixtures/angular-smoke"
assert_contains "$angular_fixture/package.json" '"@angular/cli":'
assert_contains "$angular_fixture/package.json" '"@angular-devkit/build-angular":'
assert_contains "$angular_fixture/package.json" '"start:debug":'
assert_contains "$angular_fixture/package.json" '"typescript":'
assert_contains "$angular_fixture/package.json" '"eslint":'
assert_contains "$angular_fixture/package.json" '"prettier":'
assert_contains "$angular_fixture/angular.json" '"sourceMap": true'
assert_contains "$angular_fixture/.vscode/launch.json" '"type": "pwa-chrome"'
assert_contains "$angular_fixture/.vscode/launch.json" '"address": "127.0.0.1"'
assert_contains "$angular_fixture/.vscode/launch.json" "\"cwd\": \"\${workspaceFolder}\""

python_fixture="$repo_root/tests/fixtures/python-smoke"
assert_contains "$python_fixture/pyproject.toml" '"pytest>='
assert_contains "$python_fixture/pyproject.toml" '"ruff>='
assert_contains "$python_fixture/.vscode/launch.json" '"type": "debugpy"'

printf 'Neovim and developer-tool ownership checks passed.\n'
