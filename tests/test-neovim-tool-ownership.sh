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
  '"/libexec/netcoredbg/netcoredbg"'
assert_contains "$dotnet_config" '{ warn = false }'
assert_contains "$dotnet_config" 'auto_register_dap = true'
assert_contains "$dotnet_config" '"jay-babu/mason-nvim-dap.nvim"'
assert_contains "$dotnet_config" 'coreclr = function() end'

command -v nvim >/dev/null 2>&1 || fail "nvim is required for first-launch tests"
nvim_log="$(mktemp)"
trap 'rm -f -- "$nvim_log"' EXIT
NVIM_LOG_FILE="$nvim_log" nvim --headless -u NONE -i NONE \
  -c 'lua dofile("tests/test-neovim-first-launch.lua")' \
  -c 'quitall!'
DOTFILES_TEST_ROOT="$repo_root" NVIM_LOG_FILE="$nvim_log" \
  nvim --headless -u NONE -i NONE -l tests/test-ocaml-dap.lua

formatting_config="$lazyvim_config/lua/plugins/formatting.lua"
assert_contains "$formatting_config" 'cs = { "csharpier" }'
assert_contains "$formatting_config" 'typescript = { "prettier" }'
assert_contains "$formatting_config" 'htmlangular = { "prettier" }'
assert_contains "$formatting_config" 'python = { "ruff_format" }'
assert_contains "$lazyvim_config/lua/config/options.lua" \
  'vim.g.lazyvim_eslint_auto_format = false'

ocaml_config="$lazyvim_config/lua/plugins/ocaml.lua"
assert_contains "$ocaml_config" 'vim.fn.executable("opam") == 1'
assert_contains "$ocaml_config" 'table.insert(opts.ensure_installed, "ocaml")'
assert_contains "$ocaml_config" 'mason = false'
assert_contains "$ocaml_config" \
  'cmd = { "opam", "exec", "--", "ocamllsp" }'
assert_contains "$ocaml_config" 'dap.adapters.ocamlearlybird'
assert_contains "$ocaml_config" \
  'args = { "exec", "--", "ocamlearlybird", "debug" }'
assert_contains "$ocaml_config" 'require("config.ocaml_dune")'
assert_contains "$ocaml_config" 'OCaml: build and debug Dune executable'
assert_contains "$ocaml_config" 'OCaml: debug bytecode executable (manual)'

ocaml_dune_config="$lazyvim_config/lua/config/ocaml_dune.lua"
assert_contains "$ocaml_dune_config" '"dune-workspace", "dune-project"'
assert_contains "$ocaml_dune_config" '"describe",'
assert_contains "$ocaml_dune_config" '"rules",'
assert_contains "$ocaml_dune_config" '%(targets%s*%(%(files%s*%('
assert_contains "$ocaml_dune_config" '"dune", "build", target'
assert_contains "$ocaml_dune_config" 'last_target_by_root'
assert_contains "$ocaml_dune_config" 'return require("dap").ABORT'
assert_contains "$ocaml_dune_config" '%(map_workspace_root%s+false%)'
assert_contains "$ocaml_dune_config" 'check_dune_project(root)'

assert_contains "$repo_root/platforms/fedora/scripts/install-system.sh" '  ShellCheck'

mason_inventory_file="$lazyvim_config/mason-packages.txt"
mapfile -t mason_inventory <"$mason_inventory_file"

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

[[ "${mason_inventory[*]}" == "${expected_mason_packages[*]}" ]] ||
  fail "tracked Mason inventory does not match the intended package set"

mason_config="$lazyvim_config/lua/plugins/mason.lua"
assert_contains "$mason_config" 'require("config.mason").packages()'
assert_contains "$mason_config" 'vim.env.DOTFILES_MASON_BOOTSTRAP == "1"'
assert_contains "$mason_config" 'lazy = false'
assert_contains "$dotnet_config" 'vim.env.DOTFILES_MASON_BOOTSTRAP == "1"'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  'nvim-lazyvim/.config/nvim/mason-packages.txt'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  "-u NONE -l \"\$DOTFILES_ROOT/common/bootstrap-mason.lua\""
assert_contains "$repo_root/common/bootstrap-mason.lua" \
  'require("mason.api.command").MasonInstall'
assert_contains "$repo_root/platforms/fedora/install.sh" \
  'common/install-neovim-tools.sh'
assert_contains "$repo_root/platforms/fedora-wsl/install.sh" \
  'common/install-neovim-tools.sh'
assert_contains "$repo_root/platforms/fedora/scripts/verify.sh" \
  'nvim-lazyvim/.config/nvim/mason-packages.txt'
assert_contains "$repo_root/platforms/fedora/scripts/verify.sh" \
  "fail \"Mason package not installed: \$package\""
assert_contains "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  'nvim-lazyvim/.config/nvim/mason-packages.txt'
assert_contains "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  "fail \"Mason package not installed: \$package\""

if printf '%s\n' "${mason_inventory[@]}" | grep -Fxq 'ocaml-lsp' ||
  printf '%s\n' "${mason_inventory[@]}" | grep -Fxq 'ocamlformat'; then
  fail "OCaml switch tooling must not be Mason-managed"
fi

project_tools=(
  csharpier
  dotnet-ef
  eslint
  prettier
  pytest
  trx2junit
  typescript
  dune
  earlybird
  ocaml-lsp-server
  ocamlformat
  utop
)

for tool in "${project_tools[@]}"; do
  if grep -Fiq -- "$tool" "$repo_root/mise/.config/mise/config.toml"; then
    fail "project-local tool is declared through mise: $tool"
  fi

  if printf '%s\n' "${mason_inventory[@]}" | grep -Fxq "$tool"; then
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
