#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/theme-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/theme-state.sh"

theme="${1:-macchiato}"
shift || true
[[ $# -eq 0 ]] || die "Unknown option: $1"

case "$theme" in
latte | frappe | macchiato | mocha)
  ;;
*)
  die "Invalid Catppuccin flavour: $theme"
  ;;
esac

state_dir="$XDG_CONFIG_HOME/dotfiles"
git_dir="$XDG_CONFIG_HOME/git"
former_git_dir="$DOTFILES_ROOT/git/.config/git"

ensure_dir "$state_dir"

restore_former_git_config() {
  local name="$1"
  local destination="$2"
  local repo_relative_path="git/.config/git/$name"
  local former_stow_path="$DOTFILES_ROOT/$repo_relative_path"
  local revision
  local restored="false"

  if [[ -f "$former_stow_path" ]]; then
    cp -- "$former_stow_path" "$destination"
    restored="true"
  else
    while IFS= read -r revision; do
      if git -C "$DOTFILES_ROOT" cat-file -e \
        "${revision}:${repo_relative_path}" 2>/dev/null; then
        git -C "$DOTFILES_ROOT" show \
          "${revision}:${repo_relative_path}" >"$destination"
        restored="true"
        break
      fi
    done < <(
      git -C "$DOTFILES_ROOT" log --all --format='%H' -- \
        "$repo_relative_path" 2>/dev/null
    )
  fi

  chmod 600 "$destination"
  [[ "$restored" == "true" ]]
}

migrate_folded_git_directory() {
  [[ -L "$git_dir" ]] || return 0

  if [[ "$(resolve_symlink_target "$git_dir" || true)" != "$former_git_dir" ]]; then
    info "Keeping existing Git config directory symlink: $git_dir"
    return
  fi

  local migration_dir
  local identity

  # Older Stow defaults could make the whole Git directory one symlink. Keep
  # only machine-local identities; the shared files are restowed afterward.
  migration_dir="$(mktemp -d "$XDG_CONFIG_HOME/.git-migration.XXXXXX")"

  for identity in local drdk; do
    : >"$migration_dir/$identity"
    restore_former_git_config "$identity" "$migration_dir/$identity" || true
  done

  rm -- "$git_dir"
  mv -- "$migration_dir" "$git_dir"
  info "Unfolded legacy Stow-managed Git config directory: $git_dir"
}

migrate_folded_git_directory
ensure_dir "$git_dir"

migrate_stow_managed_git_config() {
  local name="$1"
  local config_path="$git_dir/$name"
  local former_stow_path="$former_git_dir/$name"

  if [[ ! -L "$config_path" ]]; then
    if [[ ! -e "$config_path" ]]; then
      : >"$config_path"
      chmod 600 "$config_path"
    fi

    return
  fi

  if [[ "$(resolve_symlink_target "$config_path" || true)" != "$former_stow_path" ]]; then
    info "Keeping existing Git config symlink: $config_path"
    return
  fi

  local replacement
  local restored="false"

  replacement="$(mktemp "$git_dir/.${name}.XXXXXX")"

  if restore_former_git_config "$name" "$replacement"; then
    restored="true"
  fi

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
write_theme_state "$current_theme"

# Identity files are intentionally local. Migrate links created by older
# versions of this repository before Stow runs, then keep the files outside
# the Stow package.
migrate_stow_managed_git_config "local"
migrate_stow_managed_git_config "drdk"

success "Machine-local configuration initialized"
