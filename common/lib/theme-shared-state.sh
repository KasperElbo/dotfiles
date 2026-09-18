#!/usr/bin/env bash

# The portable half of applying a theme: the derived state files every
# platform reads. Sourced by setup-local.sh and by the user-facing theme
# command. The Fedora desktop half lives in platforms/fedora/lib/theme-desktop.sh.
#
# It needs ensure_dir and atomic_write_file from lib/common.sh, and sources
# that itself, so it is correct sourced standalone.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

write_theme_state() {
  local flavour="$1"
  local state_dir="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"

  ensure_dir "$state_dir"

  printf '%s\n' "$flavour" | atomic_write_file "$state_dir/theme"
  printf 'theme = catppuccin-%s.conf\n' "$flavour" \
    | atomic_write_file "$state_dir/ghostty.conf"
  printf '[delta]\n    features = catppuccin-%s\n' "$flavour" \
    | atomic_write_file "$state_dir/git-theme"
  printf 'set -g @catppuccin_flavor "%s"\n' "$flavour" \
    | atomic_write_file "$state_dir/tmux-theme.conf"
}
