#!/usr/bin/env bash

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

theme="${1:-macchiato}"

case "$theme" in
latte | frappe | macchiato | mocha)
  ;;
*)
  die "Invalid Catppuccin flavour: $theme"
  ;;
esac

state_dir="$XDG_CONFIG_HOME/dotfiles"
git_dir="$XDG_CONFIG_HOME/git"

ensure_dir "$state_dir"
ensure_dir "$git_dir"

# Do not overwrite a user's existing theme choice.
if [[ ! -e "$state_dir/theme" ]]; then
  printf '%s\n' "$theme" >"$state_dir/theme"
  info "Created theme preference: $theme"
else
  info "Keeping existing theme preference: $(cat "$state_dir/theme")"
fi

# Derived local configuration. These contain no secrets.
current_theme="$(cat "$state_dir/theme")"

printf 'theme = catppuccin-%s.conf\n' "$current_theme" \
  >"$state_dir/ghostty.conf"

printf '[delta]\n    features = catppuccin-%s\n' "$current_theme" \
  >"$state_dir/git-theme"

printf 'set -g @catppuccin_flavor "%s"\n' "$current_theme" \
  >"$state_dir/tmux-theme.conf"

# Identity files are intentionally local and are NEVER populated
# automatically with somebody else's details.
touch "$git_dir/local"
touch "$git_dir/drdk"

success "Machine-local configuration initialized"
