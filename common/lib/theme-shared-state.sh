#!/usr/bin/env bash

# The portable half of applying a theme: the derived state files every
# platform reads. Sourced by setup-local.sh and by the user-facing theme
# command. The Fedora desktop half lives in platforms/fedora/lib/theme-desktop.sh.

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
