#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

require_command stow

"$DOTFILES_ROOT/common/stow.sh"

platform_stow_dir="$DOTFILES_ROOT/platforms/macos/stow"
packages=(zsh-platform aerospace)

info "Stowing macOS user integration into $HOME"
for package in "${packages[@]}"; do
  [[ -d "$platform_stow_dir/$package" ]] || die "Missing macOS Stow package: $package"
  stow \
    --dir="$platform_stow_dir" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "macOS user integration stowed"
