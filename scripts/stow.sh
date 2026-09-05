#!/usr/bin/env bash

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command stow

install_sway="false"

while (($#)); do
  case "$1" in
  --sway)
    install_sway="true"
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
  ghostty
  git
  lazygit
  mise
  nvim-lazyvim
  starship
  tmux
  zsh
)

if [[ "$install_sway" == "true" ]]; then
  packages+=(sway waybar)
fi

info "Stowing dotfiles into $HOME"

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

success "Dotfiles stowed"
