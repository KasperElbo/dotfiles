#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lazyvim_config="$repo_root/nvim-lazyvim/.config/nvim"
# shellcheck source=lib/lazy-nvim.sh
source "$repo_root/tests/lib/lazy-nvim.sh"

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
  lazyvim.plugins.extras.formatting.prettier
  lazyvim.plugins.extras.lang.angular
  lazyvim.plugins.extras.lang.json
  lazyvim.plugins.extras.lang.markdown
  lazyvim.plugins.extras.lang.python
  lazyvim.plugins.extras.lang.tex
  lazyvim.plugins.extras.lang.yaml
  lazyvim.plugins.extras.linting.eslint
  lazyvim.plugins.extras.test.core
)

profile_config="$lazyvim_config/lua/config/profile.lua"
for extra in "${lazyvim_extras[@]}"; do
  assert_contains "$profile_config" "\"$extra\""
done
assert_contains "$lazyvim_config/lazyvim.json" '"extras": []'
assert_contains "$profile_config" '["parrot-ctf"]'
assert_contains "$profile_config" 'plugins = "ctf_plugins"'
assert_contains "$profile_config" 'profiles/parrot-ctf/mason-packages.txt'
assert_contains "$profile_config" 'profiles/parrot-ctf/lazy-lock.json'
assert_contains "$profile_config" 'vim.env.DOTFILES_MASON_BOOTSTRAP == "1"'
assert_contains "$profile_config" '"nvim-treesitter/nvim-treesitter"'
assert_contains "$profile_config" 'enabled = false'
assert_contains "$lazyvim_config/lua/config/lazy.lua" 'spec = profile.spec()'
assert_contains "$lazyvim_config/lua/config/lazy.lua" 'lockfile = profile.lockfile()'
assert_contains "$lazyvim_config/lua/config/lazy.lua" \
  'vim.g.lazyvim_python_lsp = "basedpyright"'

dotnet_config="$lazyvim_config/lua/plugins/dotnet.lua"
assert_contains "$dotnet_config" '"roslyn"'
assert_contains "$dotnet_config" '"netcoredbg"'
assert_contains "$dotnet_config" 'lsp = {'
assert_contains "$dotnet_config" 'enabled = false'
assert_contains "$dotnet_config" 'engine = "netcoredbg"'
assert_contains "$dotnet_config" 'auto_register_dap = true'
assert_contains "$dotnet_config" '"jay-babu/mason-nvim-dap.nvim"'
assert_contains "$dotnet_config" 'coreclr = function() end'
if grep -Fq 'bin_path' "$dotnet_config" || grep -Fq 'LazyVim.get_pkg_path' "$dotnet_config"; then
  fail "EasyDotnet must resolve its bundled debugger instead of a Mason path"
fi

command -v nvim >/dev/null 2>&1 || fail "nvim is required for first-launch tests"
nvim_log="$(mktemp)"
lua_output="$(mktemp)"
trap 'rm -f -- "$nvim_log" "$lua_output"' EXIT

# `nvim -l` is the supported standalone-Lua entry point on the pinned 0.12
# baseline: an uncaught error becomes Neovim's exit status. The older
# `-c 'lua dofile(...)' -c 'quitall!'` form printed the very same error and
# still exited 0, because the trailing quit command overwrote the failure.
run_nvim_lua_test() {
  local script="$1"
  shift

  env "$@" NVIM_LOG_FILE="$nvim_log" \
    nvim --headless -u NONE -i NONE -l "$script" >"$lua_output" 2>&1
}

report_nvim_lua_output() {
  printf 'Captured Neovim output:\n' >&2
  sed 's/^/  /' "$lua_output" >&2
}

run_nvim_lua_test tests/test-neovim-first-launch.lua || {
  report_nvim_lua_output
  fail "Neovim first-launch Lua test failed"
}

# Prove the harness cannot go green on a failed Lua assertion. The fixture uses
# the same invocation path as the real test, so a regression in the invocation
# form is caught here rather than silently masking future failures.
sentinel_fixture="tests/fixtures/neovim-first-launch-sentinel.lua"
if run_nvim_lua_test "$sentinel_fixture"; then
  report_nvim_lua_output
  fail "a deliberately failing Lua fixture did not fail the Neovim test harness"
fi
grep -Fq "$sentinel_fixture" "$lua_output" || {
  report_nvim_lua_output
  fail "Neovim failure output does not name the failing Lua file"
}
grep -Fq 'dotfiles first-launch sentinel' "$lua_output" || {
  report_nvim_lua_output
  fail "Neovim failure output does not name the failing assertion"
}

run_nvim_lua_test tests/test-ocaml-dap.lua "DOTFILES_TEST_ROOT=$repo_root" || {
  report_nvim_lua_output
  fail "Neovim OCaml DAP Lua test failed"
}

# --- The theme reload survives platform overlay merging --------------------

# lazy.nvim merges only opts, dependencies, cmd, event, ft and keys; every
# other key is overridden by the fragment imported last. Reading the fragments
# cannot see that, so this resolves the real spec set through lazy.nvim with a
# platform overlay stowed alongside the shared fragments (#248, RA-36).
lazy_nvim="${DOTFILES_LAZY_NVIM:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim}"
[[ -d "$lazy_nvim/lua/lazy" ]] ||
  fail "lazy.nvim is required to resolve plugin specs; set DOTFILES_LAZY_NVIM to a checkout (looked in $lazy_nvim)"

spec_root="$(mktemp -d)"
trap 'rm -f -- "$nvim_log" "$lua_output"; rm -rf -- "$spec_root"' EXIT

# Stow in miniature: an overlay's fragments land in the same lua/plugins
# directory as the shared ones, which is what makes them one lazy.nvim module.
stow_overlay_config() {
  local overlay="$1" flavour="$2" destination="$3" replacement="${4:-}"

  rm -rf -- "$destination"
  mkdir -p "$destination/config" "$destination/xdg/dotfiles" "$destination/home"
  cp -r "$lazyvim_config/." "$destination/config/"
  cp "$repo_root"/platforms/*/stow/"$overlay"/.config/nvim/lua/plugins/*.lua \
    "$destination/config/lua/plugins/"
  if [[ -n "$replacement" ]]; then
    cp "$replacement" "$destination/config/lua/plugins/colorscheme.lua"
  fi
  printf '%s\n' "$flavour" >"$destination/xdg/dotfiles/theme"
}

run_theme_reload_test() {
  local overlay="$1" flavour="$2" destination="$3"

  run_nvim_lua_test tests/test-neovim-theme-reload.lua \
    "DOTFILES_TEST_NVIM_CONFIG=$destination/config" \
    "DOTFILES_TEST_LAZY=$lazy_nvim" \
    "DOTFILES_TEST_SCRATCH=$destination/state" \
    "DOTFILES_TEST_OVERLAY=$overlay" \
    "DOTFILES_TEST_FLAVOUR=$flavour" \
    "XDG_CONFIG_HOME=$destination/xdg" \
    "XDG_DATA_HOME=$destination/data" \
    "HOME=$destination/home"
}

for overlay_case in nvim-macos:latte nvim-wsl:mocha; do
  overlay="${overlay_case%%:*}"
  flavour="${overlay_case##*:}"
  stow_overlay_config "$overlay" "$flavour" "$spec_root/$overlay"
  run_theme_reload_test "$overlay" "$flavour" "$spec_root/$overlay" || {
    report_nvim_lua_output
    fail "refocusing does not reload the theme once the $overlay overlay is stowed"
  }
done

# The control. With the reload registered from the contended "LazyVim/LazyVim"
# init, as it was before #248, the same test must fail: a harness that passes
# either way proves nothing.
contended="$repo_root/tests/fixtures/neovim-contended-init/colorscheme.lua"
stow_overlay_config nvim-macos latte "$spec_root/contended" "$contended"
if run_theme_reload_test nvim-macos latte "$spec_root/contended"; then
  report_nvim_lua_output
  fail "the theme-reload test passes even when the overlay overrides the shared init"
fi
grep -Fq 'FocusGained' "$lua_output" || {
  report_nvim_lua_output
  fail "the theme-reload failure does not name the missing FocusGained autocmd"
}

# --- The guard that keeps the contended arrangement from coming back -------

python3 "$repo_root/scripts/validate-neovim-plugin-specs.py" >/dev/null ||
  fail "the tracked plugin fragments do not pass scripts/validate-neovim-plugin-specs.py"

scratch_tree="$spec_root/validator"
mkdir -p "$scratch_tree/nvim-lazyvim/.config/nvim/lua/plugins" \
  "$scratch_tree/platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins"
cp "$lazyvim_config"/lua/plugins/*.lua "$scratch_tree/nvim-lazyvim/.config/nvim/lua/plugins/"
cp "$contended" "$scratch_tree/nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua"
cp "$repo_root"/platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/*.lua \
  "$scratch_tree/platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/"

validator_status=0
validator_output="$(python3 "$repo_root/scripts/validate-neovim-plugin-specs.py" \
  --root "$scratch_tree" 2>&1)" || validator_status=$?
((validator_status != 0)) ||
  fail "the plugin-spec validator accepts two fragments declaring init on one spec"
grep -Fq 'LazyVim/LazyVim' <<<"$validator_output" ||
  fail "the plugin-spec validator does not name the contended plugin: $validator_output"
grep -Fq 'init' <<<"$validator_output" ||
  fail "the plugin-spec validator does not name the contended key: $validator_output"

# The verifier's Neovim baseline check runs Lua through an Ex command, where an
# uncaught error never reaches the exit status. It must convert a failed check
# into `cquit` rather than relying on the error propagating on its own.
#
# The assertion follows the rule rather than the file: the Lua used to be
# written out in the Fedora verifier, and now neovim_verify_floor_assertion in
# the shared library builds it for all four platforms.
verify_library="$repo_root/common/lib/verify.sh"
assert_contains "$verify_library" 'cquit 1'
assert_contains "$verify_library" 'neovim_verify_floor_assertion'
# And the platforms ask for it through that helper rather than rolling their
# own, which is what keeps the rule in one place.
for platform_verifier in "$repo_root"/platforms/*/scripts/verify.sh; do
  grep -Fq 'nvim --headless' "$platform_verifier" || continue
  grep -Fq 'cquit' "$platform_verifier" &&
    fail "platform verifier writes its own floor assertion: ${platform_verifier#"$repo_root/"}"
done
# Wherever the Lua is written, it must not lean on assert: an uncaught Lua
# error raised from an Ex command never reaches the exit status.
for lua_host in "$verify_library" "$repo_root"/platforms/*/scripts/verify.sh; do
  if grep -Fq '+lua assert(' "$lua_host"; then
    fail "asserts in an Ex command, where a Lua failure cannot fail the run: ${lua_host#"$repo_root/"}"
  fi
done

formatting_config="$lazyvim_config/lua/plugins/formatting.lua"
assert_contains "$formatting_config" 'cs = { "csharpier" }'
# CSharpier must resolve through the project's local tool manifest rather than
# Conform's built-in fallback to a bare executable; see tests/test-csharpier-*.
assert_contains "$formatting_config" 'require("config.csharpier").formatter()'
assert_contains "$lazyvim_config/lua/config/csharpier.lua" 'command = "dotnet"'
assert_contains "$lazyvim_config/lua/config/csharpier.lua" 'require_cwd = true'
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
mason_inventory_text="$(printf '%s\n' "${mason_inventory[@]}")"

expected_mason_packages=(
  angular-language-server
  debugpy
  eslint-lsp
  js-debug-adapter
  json-lsp
  lua-language-server
  marksman
  prettier
  pyright
  roslyn
  ruff
  shfmt
  stylua
  texlab
  tree-sitter-cli
  vtsls
  yaml-language-server
)

[[ "${mason_inventory[*]}" == "${expected_mason_packages[*]}" ]] ||
  fail "tracked Mason inventory does not match the intended package set"

parrot_mason_inventory_file="$lazyvim_config/profiles/parrot-ctf/mason-packages.txt"
mapfile -t parrot_mason_inventory <"$parrot_mason_inventory_file"
expected_parrot_mason=(
  basedpyright
  debugpy
  lua-language-server
  ruff
  stylua
  tree-sitter-cli
)
[[ "${parrot_mason_inventory[*]}" == "${expected_parrot_mason[*]}" ]] ||
  fail "Parrot Mason inventory does not match the reduced package set"
for excluded in angular-language-server eslint-lsp js-debug-adapter json-lsp \
  marksman netcoredbg prettier pyright roslyn texlab vtsls yaml-language-server; do
  if grep -Fxq "$excluded" "$parrot_mason_inventory_file"; then
    fail "workstation Mason package leaked into Parrot profile: $excluded"
  fi
done

mason_config="$lazyvim_config/lua/plugins/mason.lua"
assert_contains "$mason_config" 'require("config.mason").packages()'
assert_contains "$mason_config" 'vim.env.DOTFILES_MASON_BOOTSTRAP == "1"'
assert_contains "$mason_config" 'lazy = false'
assert_contains "$dotnet_config" 'vim.env.DOTFILES_MASON_BOOTSTRAP == "1"'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  'nvim-lazyvim/.config/nvim/mason-packages.txt'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  'nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  "-u NONE -l \"\$DOTFILES_ROOT/common/bootstrap-mason.lua\""
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  'common/mason-package-versions.txt'

# A version pin only makes sense for a package some profile actually installs,
# and an unreadable pin file would silently stop pinning anything.
mason_pin_file="$repo_root/common/mason-package-versions.txt"
[[ -r "$mason_pin_file" ]] || fail "Mason version pin file is missing: $mason_pin_file"
while read -r pinned_package pinned_version pinned_extra; do
  [[ -n "$pinned_package" ]] || continue
  [[ -z "$pinned_extra" ]] || fail "Malformed Mason version pin: $pinned_package"
  [[ -n "$pinned_version" ]] ||
    fail "Mason version pin is missing a version: $pinned_package"
  if ! grep -Fxq "$pinned_package" "$mason_inventory_file" &&
    ! grep -Fxq "$pinned_package" "$parrot_mason_inventory_file"; then
    fail "Mason version pin names a package no profile installs: $pinned_package"
  fi
done < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$mason_pin_file")
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  'Package is already installing|Neovim is exiting while packages are still installing'
assert_contains "$repo_root/common/install-neovim-tools.sh" \
  "'+Lazy! restore mason.nvim'"
assert_contains "$repo_root/common/bootstrap-mason.lua" \
  'require("mason.api.command").MasonInstall'
assert_contains "$repo_root/platforms/fedora/install.sh" \
  'common/install-neovim-tools.sh'
assert_contains "$repo_root/platforms/fedora-wsl/install.sh" \
  'common/install-neovim-tools.sh'
for verifier in platforms/fedora platforms/fedora-wsl platforms/macos; do
  assert_contains "$repo_root/$verifier/scripts/verify.sh" \
    'check_mason_inventory "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"'
done
assert_contains "$repo_root/common/lib/verify.sh" \
  "fail \"Mason package not installed: \$package\""
assert_contains "$repo_root/platforms/parrot-ctf/install.sh" \
  'common/install-neovim-tools.sh" --profile parrot-ctf'
assert_contains "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  'Mason inventory mismatch'

if grep -Fxq 'ocaml-lsp' <<<"$mason_inventory_text" ||
  grep -Fxq 'ocamlformat' <<<"$mason_inventory_text"; then
  fail "OCaml switch tooling must not be Mason-managed"
fi

# Prettier is the one deliberate exception to the project-only rule below: a
# project's own Prettier still wins through Conform's node_modules resolution,
# and the Mason copy exists so a standalone JSON, YAML or Markdown file is
# formattable on a clean install. Every other project tool stays project-owned.
project_tools=(
  csharpier
  dotnet-ef
  eslint
  pytest
  trx2junit
  typescript
  dune
  earlybird
  ocaml-lsp-server
  ocamlformat
  utop
  markdown-toc
  markdownlint-cli2
)

for tool in "${project_tools[@]}"; do
  if grep -Fiq -- "$tool" "$repo_root/mise/.config/mise/config.toml"; then
    fail "project-local tool is declared through mise: $tool"
  fi

  if grep -Fxq "$tool" <<<"$mason_inventory_text"; then
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
