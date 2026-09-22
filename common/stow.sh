#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"

# Stow is given one target, $HOME. An XDG root pointing anywhere else would
# have it link configuration where nothing later reads it, so that is refused
# before a single link is made -- and before the prerequisite check below, so
# the answer does not depend on whether Stow happens to be installed.
preflight_xdg_layout || die "Refusing to stow; nothing in $HOME was changed."

require_command stow

headless="false"
without_mise="false"

while (($#)); do
  case "$1" in
  --headless)
    headless="true"
    ;;
  --without-mise)
    without_mise="true"
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
  shift
done

packages=(
  bat
  bin
  fzf
  git
  lazygit
  nvim-lazyvim
  starship
  tmux
  zsh
)

if [[ "$without_mise" == "false" ]]; then
  packages+=(mise)
fi

if [[ "$headless" == "false" ]]; then
  packages+=(ghostty)
fi

# Refuse before linking anything. Stow aborts on the first conflicting package,
# but only after the packages before it are already linked, so without this a
# run that hits a conflict leaves a partly stowed HOME behind.
#
# A package directory this checkout does not have is a missing package, not a
# package to leave out, so it is passed to the check like every other one and
# refuses the run. Skipping it instead deployed none of that package's
# configuration and still reported success.
specs=()
for package in "${packages[@]}"; do
  specs+=("$DOTFILES_ROOT::$package")
done
preflight_stow_packages "${specs[@]}" ||
  die "Refusing to stow; nothing in $HOME was changed."

info "Stowing portable dotfiles into $HOME"

for package in "${packages[@]}"; do
  package_dir="$DOTFILES_ROOT/$package"

  [[ -d "$package_dir" ]] || die "Missing Stow package: $package"

  info "Stowing $package"
  stow \
    --dir="$DOTFILES_ROOT" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Portable dotfiles stowed"
