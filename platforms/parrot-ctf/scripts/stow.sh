#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/preflight.sh"

require_command stow
[[ $# -eq 0 ]] || die "Unknown option: $1"

platform_stow_dir="$DOTFILES_ROOT/platforms/parrot-ctf/stow"
packages=(command-shims mise-ctf neovim-profile zsh-platform)

# Checked before common/stow.sh links anything, which checks its own packages
# the same way, so no conflict is found after part of HOME is already stowed.
specs=()
for package in "${packages[@]}"; do specs+=("$platform_stow_dir::$package"); done
preflight_stow_packages "${specs[@]}" || die "Refusing to stow; nothing in $HOME was changed."

# The normal workstation mise manifest is deliberately not part of this
# profile. Parrot gets a narrow manifest below instead.
"$DOTFILES_ROOT/common/stow.sh" --headless --without-mise

info "Stowing Parrot CTF integration into $HOME"
for package in "${packages[@]}"; do
  [[ -d "$platform_stow_dir/$package" ]] ||
    die "Missing Parrot CTF Stow package: $package"
  stow --dir="$platform_stow_dir" --target="$HOME" --restow --no-folding \
    "$package"
done

success "Parrot CTF integration stowed"
