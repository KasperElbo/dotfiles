#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

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

info "Stowing portable dotfiles into $HOME"

for package in "${packages[@]}"; do
  package_dir="$DOTFILES_ROOT/$package"

  if [[ ! -d "$package_dir" ]]; then
    warn "Skipping missing package: $package"
    continue
  fi

  info "Stowing $package"
  stow \
    --dir="$DOTFILES_ROOT" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Portable dotfiles stowed"
