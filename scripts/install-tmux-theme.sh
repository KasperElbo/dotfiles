#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command git

version="v2.3.0"
install_dir="$XDG_DATA_HOME/tmux/plugins/catppuccin"
repo="https://github.com/catppuccin/tmux.git"

ensure_dir "$(dirname "$install_dir")"

if [[ ! -d "$install_dir/.git" ]]; then
  info "Installing Catppuccin tmux $version"

  git clone \
    --branch "$version" \
    --depth 1 \
    "$repo" \
    "$install_dir"
else
  info "Updating Catppuccin tmux to $version"

  git -C "$install_dir" fetch \
    --depth 1 \
    origin \
    "refs/tags/$version:refs/tags/$version"

  git -C "$install_dir" checkout --detach "$version"
fi

[[ -f "$install_dir/catppuccin.tmux" ]] ||
  die "Catppuccin tmux installation is incomplete"

success "Catppuccin tmux $version installed"
