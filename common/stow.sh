#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command stow

[[ $# -eq 0 ]] || die "Unknown option: $1"

packages=(
  bat
  bin
  fzf
  ghostty
  git
  lazygit
  mise
  nvim-lazyvim
  starship
  tmux
  zsh
)

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
