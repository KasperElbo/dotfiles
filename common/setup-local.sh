#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/theme-shared-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/theme-shared-state.sh"
# shellcheck source=lib/git-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-identity.sh"
# shellcheck source=lib/theme-selection.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/theme-selection.sh"

# The platform names which option manifest rows the flavour is checked against.
(($# >= 1 && $# <= 2)) || die 'Usage: common/setup-local.sh PLATFORM [FLAVOUR]'
platform="$1"
theme="${2:-$THEME_DEFAULT_FLAVOUR}"

install_option_exists "$platform" theme ||
  die "No theme option is declared for platform: $platform"
theme_flavour_is_valid "$platform" "$theme" ||
  die "Invalid Catppuccin flavour: $theme"

state_dir="$XDG_CONFIG_HOME/dotfiles"
git_dir="$XDG_CONFIG_HOME/git"
former_git_dir="$DOTFILES_ROOT/git/.config/git"

ensure_dir "$state_dir"

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
  chmod 700 "$migration_dir"

  for identity in "${GIT_IDENTITY_NAMES[@]}"; do
    git_identity_migrate "$identity" "$migration_dir/$identity"
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

  GIT_IDENTITY_OUTCOME="$GIT_IDENTITY_OUTCOME_NONE"

  if [[ ! -L "$config_path" ]]; then
    # Not a legacy link: either already machine-local, or a fresh machine that
    # gets an empty placeholder for the user to fill in.
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

  git_identity_migrate "$name" "$config_path"
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
# the Stow package. The outcome of each slot is reported explicitly, by slot
# name and outcome only: identity content is never printed.
identity_migrated=0
identity_manual=0
for identity_name in "${GIT_IDENTITY_NAMES[@]}"; do
  migrate_stow_managed_git_config "$identity_name"
  case "$GIT_IDENTITY_OUTCOME" in
  "$GIT_IDENTITY_OUTCOME_MIGRATED") identity_migrated=$((identity_migrated + 1)) ;;
  "$GIT_IDENTITY_OUTCOME_MANUAL") identity_manual=$((identity_manual + 1)) ;;
  esac
done

if ((identity_manual > 0)); then
  warn "Git identity migration: $identity_manual slot(s) need manual action, $identity_migrated migrated."
elif ((identity_migrated > 0)); then
  info "Git identity migration: $identity_migrated slot(s) migrated."
else
  info "Git identity migration: nothing to migrate."
fi

success "Machine-local configuration initialized"
