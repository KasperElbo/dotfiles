#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command nvim
require_command timeout

inventory_file="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"
[[ -r "$inventory_file" ]] || die "Mason package inventory not found: $inventory_file"

mapfile -t mason_packages < <(
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$inventory_file"
)
((${#mason_packages[@]} > 0)) || die "Mason package inventory is empty"

for package in "${mason_packages[@]}"; do
  [[ "$package" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "Invalid Mason package name in inventory: $package"
done

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
  local description="$1"
  shift
  local status

  info "$description"
  if DOTFILES_MASON_BOOTSTRAP=1 timeout --kill-after=30s \
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

# A separate blocking lazy.nvim pass makes Mason and its command available on
# a completely clean account before the package installation process starts.
run_nvim_phase "Restoring LazyVim plugins" '+Lazy! restore' +qa

mason_root="$XDG_DATA_HOME/nvim/mason/packages"
missing_packages=()
for package in "${mason_packages[@]}"; do
  [[ -d "$mason_root/$package" ]] || missing_packages+=("$package")
done

if ((${#missing_packages[@]} > 0)); then
  # Load Mason directly for this phase. This prevents LazyVim's filetype- and
  # DAP-triggered installers from racing the blocking Mason command.
  DOTFILES_MASON_PLUGIN="$XDG_DATA_HOME/nvim/lazy/mason.nvim" \
    DOTFILES_MASON_PACKAGES="${missing_packages[*]}" \
    run_nvim_phase "Installing Mason editor tools" \
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

success "LazyVim plugins and Mason editor tools installed"
