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

migrate_stow_managed_git_config() {
  local name="$1"
  local config_path="$git_dir/$name"
  local repo_relative_path="git/.config/git/$name"
  local former_stow_path="$DOTFILES_ROOT/$repo_relative_path"

  if [[ ! -L "$config_path" ]]; then
    touch "$config_path"
    return
  fi

  if [[ "$(realpath -m "$config_path")" != "$former_stow_path" ]]; then
    info "Keeping existing Git config symlink: $config_path"
    return
  fi

  local replacement
  local revision
  local restored="false"

  replacement="$(mktemp "$git_dir/.${name}.XXXXXX")"

  if [[ -f "$former_stow_path" ]]; then
    cp -- "$former_stow_path" "$replacement"
    restored="true"
  else
    while IFS= read -r revision; do
      if git -C "$DOTFILES_ROOT" cat-file -e \
        "${revision}:${repo_relative_path}" 2>/dev/null; then
        git -C "$DOTFILES_ROOT" show \
          "${revision}:${repo_relative_path}" >"$replacement"
        restored="true"
        break
      fi
    done < <(
      git -C "$DOTFILES_ROOT" log --all --format='%H' -- \
        "$repo_relative_path" 2>/dev/null
    )
  fi

  chmod 600 "$replacement"
  mv -- "$replacement" "$config_path"

  if [[ "$restored" == "true" ]]; then
    info "Migrated Git config out of the Stow package: $config_path"
  else
    warn "Replaced obsolete Git config symlink with an empty local file: $config_path"
  fi
}

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

# Identity files are intentionally local. Migrate links created by older
# versions of this repository before Stow runs, then keep the files outside
# the Stow package.
migrate_stow_managed_git_config "local"
migrate_stow_managed_git_config "drdk"

success "Machine-local configuration initialized"
