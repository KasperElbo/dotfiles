#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

establish_user_tool_environment
require_command nvim
require_command timeout

profile="workstation"

while (($#)); do
  case "$1" in
  --profile)
    [[ $# -ge 2 ]] || die "--profile requires a value"
    profile="$2"
    shift 2
    ;;
  *) die "Unknown option: $1" ;;
  esac
done

case "$profile" in
workstation)
  inventory_file="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"
  ;;
parrot-ctf)
  inventory_file="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"
  ;;
*) die "Unsupported Neovim profile: $profile" ;;
esac

[[ -r "$inventory_file" ]] || die "Mason package inventory not found: $inventory_file"

mapfile -t mason_packages < <(
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$inventory_file"
)
((${#mason_packages[@]} > 0)) || die "Mason package inventory is empty"

for package in "${mason_packages[@]}"; do
  [[ "$package" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "Invalid Mason package name in inventory: $package"
done

if ! printf '%s\n' "${mason_packages[@]}" | grep -Fxq 'tree-sitter-cli'; then
  die "Mason inventory must include tree-sitter-cli so bootstrap has one explicit owner"
fi

bootstrap_timeout="${NEOVIM_BOOTSTRAP_TIMEOUT:-20m}"
[[ "$bootstrap_timeout" =~ ^[1-9][0-9]*[smhd]?$ ]] ||
  die "Invalid NEOVIM_BOOTSTRAP_TIMEOUT: $bootstrap_timeout"

nvim_command=(nvim)
mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi
if [[ -n "$mise_command" ]]; then
  # Mason's npm- and Python-based packages need the runtimes installed by mise
  # even though this non-interactive Bash process has not activated mise.
  nvim_command=("$mise_command" exec -- nvim)
fi

run_nvim_phase() {
  local bootstrap_mode="$1"
  local description="$2"
  shift 2
  local status

  info "$description"
  if DOTFILES_NVIM_PROFILE="$profile" DOTFILES_MASON_BOOTSTRAP="$bootstrap_mode" \
    timeout --kill-after=30s \
    "$bootstrap_timeout" "${nvim_command[@]}" --headless "$@"; then
    return
  else
    status=$?
  fi

  if ((status == 124 || status == 137)); then
    die "$description timed out after $bootstrap_timeout"
  fi
  die "$description failed with exit status $status"
}

mason_plugin="$XDG_DATA_HOME/nvim/lazy/mason.nvim"
mason_root="$XDG_DATA_HOME/nvim/mason/packages"
mason_bin="$XDG_DATA_HOME/nvim/mason/bin"

# Restore only Mason while nvim-treesitter is disabled by the bootstrap profile.
# This gives the blocking installer a usable Mason API without allowing
# LazyVim's asynchronous Treesitter build/config callbacks to install the same
# tree-sitter-cli package concurrently.
run_nvim_phase 1 "Preparing Mason plugin" '+Lazy! restore mason.nvim' +qa
[[ -d "$mason_plugin" ]] || die "Mason plugin was not restored: $mason_plugin"

missing_packages=()
for package in "${mason_packages[@]}"; do
  [[ -d "$mason_root/$package" ]] || missing_packages+=("$package")
done

if ((${#missing_packages[@]} > 0)); then
  # Load Mason directly for this phase. MasonInstall blocks until the complete
  # declared inventory has converged, so tree-sitter-cli has one installer.
  DOTFILES_MASON_PLUGIN="$mason_plugin" \
    DOTFILES_MASON_PACKAGES="${missing_packages[*]}" \
    run_nvim_phase 1 "Installing Mason editor tools" \
    -u NONE -l "$DOTFILES_ROOT/common/bootstrap-mason.lua"
else
  info "All intended Mason editor tools are already installed"
fi

remaining_packages=()
for package in "${mason_packages[@]}"; do
  [[ -d "$mason_root/$package" ]] || remaining_packages+=("$package")
done

if ((${#remaining_packages[@]} > 0)); then
  die "Mason provisioning incomplete; missing: ${remaining_packages[*]}"
fi

[[ -x "$mason_bin/tree-sitter" ]] ||
  die "Mason tree-sitter-cli is installed but does not expose $mason_bin/tree-sitter"

# Only after the blocking Mason inventory has converged do we enable the normal
# nvim-treesitter spec. Put Mason's bin directory on PATH explicitly so
# LazyVim's Treesitter health/build callbacks observe the already-installed CLI
# before Mason's normal interactive configuration has a chance to modify PATH.
restore_log="$(mktemp)"
if PATH="$mason_bin:$PATH" run_nvim_phase 0 "Restoring LazyVim plugins" '+Lazy! restore' +qa \
  > >(tee "$restore_log") 2>&1; then
  :
fi
# These diagnostics mean bootstrap ownership regressed and LazyVim tried to
# install tree-sitter-cli even though the blocking Mason phase already owns it.
# The backticks are literal fragments of LazyVim's diagnostic.
# shellcheck disable=SC2016
if grep -Eq \
  'Package is already installing|Neovim is exiting while packages are still installing|Failed to install `tree-sitter-cli` with `mason.nvim`|Installing `tree-sitter-cli` with `mason.nvim`' \
  "$restore_log"; then
  rm -f -- "$restore_log"
  die "LazyVim restore attempted a competing tree-sitter-cli installation"
fi
rm -f -- "$restore_log"

PATH="$mason_bin:$PATH" run_nvim_phase 0 "Verifying LazyVim headless startup" +qa

success "LazyVim plugins and Mason editor tools installed"
