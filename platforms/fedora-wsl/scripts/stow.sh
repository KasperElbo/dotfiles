#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/preflight.sh"

require_command stow
[[ $# -eq 0 ]] || die "Unknown option: $1"

platform_stow_dir="$DOTFILES_ROOT/platforms/fedora-wsl/stow"
packages=(interop nvim-wsl theme-hooks zsh-platform)

# Checked before common/stow.sh links anything, which checks its own packages
# the same way, so no conflict is found after part of HOME is already stowed.
specs=()
for package in "${packages[@]}"; do specs+=("$platform_stow_dir::$package"); done
preflight_stow_packages "${specs[@]}" || die "Refusing to stow; nothing in $HOME was changed."

"$DOTFILES_ROOT/common/stow.sh" --headless

info "Stowing Fedora WSL integration into $HOME"

for package in "${packages[@]}"; do
  package_dir="$platform_stow_dir/$package"
  [[ -d "$package_dir" ]] || die "Missing Fedora WSL Stow package: $package"

  info "Stowing Fedora WSL package $package"
  stow \
    --dir="$platform_stow_dir" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Fedora WSL integration stowed"
