#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/preflight.sh"

require_command stow

# theme-assets is at the top of the checkout rather than under
# platforms/macos/stow: the wallpapers are one set of images shared with
# Fedora, not a second copy cropped for this platform. Each package's root is
# therefore resolved rather than assumed, through the same helper the
# installer's preflight uses, so the two cannot disagree about which copy a
# machine gets.
packages=(zsh-platform aerospace nvim-macos ghostty-macos theme-hooks theme-assets)

# Checked before common/stow.sh links anything, which checks its own packages
# the same way, so no conflict is found after part of HOME is already stowed.
specs=()
for package in "${packages[@]}"; do
  specs+=("$(capability_stow_package_root macos "$package")::$package")
done
preflight_stow_packages "${specs[@]}" || die "Refusing to stow; nothing in $HOME was changed."

"$DOTFILES_ROOT/common/stow.sh"

info "Stowing macOS user integration into $HOME"
for package in "${packages[@]}"; do
  package_dir="$(capability_stow_package_root macos "$package")/$package"
  [[ -d "$package_dir" ]] || die "Missing Stow package: $package"
  stow \
    --dir="$(dirname "$package_dir")" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "macOS user integration stowed"
