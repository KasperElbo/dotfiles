#!/usr/bin/env bash

set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/theme-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/theme-state.sh"

theme="${1:-macchiato}"
install_sway="false"
hardware_model=""
shift || true

while (($#)); do
  case "$1" in
  --sway)
    install_sway="true"
    ;;
  --hardware)
    [[ $# -ge 2 ]] || die "--hardware requires a value"
    hardware_model="$2"
    shift
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
  shift
done

case "$theme" in
latte | frappe | macchiato | mocha)
  ;;
*)
  die "Invalid Catppuccin flavour: $theme"
  ;;
esac

case "$hardware_model" in
"" | ga402xz | ga402rk)
  ;;
*)
  die "Invalid hardware profile: $hardware_model"
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

  if [[ "$(realpath -m "$git_dir")" != "$former_git_dir" ]]; then
    info "Keeping existing Git config directory symlink: $git_dir"
    return
  fi

  local migration_dir
  local source_path
  local relative_path
  local identity

  # Older Stow defaults could make the whole Git directory one symlink. Build
  # the equivalent no-folding layout beside it before replacing that link.
  migration_dir="$(mktemp -d "$XDG_CONFIG_HOME/.git-migration.XXXXXX")"

  while IFS= read -r -d '' source_path; do
    relative_path="${source_path#"$former_git_dir"/}"

    case "$relative_path" in
    local | drdk)
      continue
      ;;
    esac

    if [[ -d "$source_path" && ! -L "$source_path" ]]; then
      mkdir -p "$migration_dir/$relative_path"
    else
      local destination_path="$migration_dir/$relative_path"
      local relative_source

      ensure_dir "$(dirname "$destination_path")"
      relative_source="$(
        realpath --relative-to="$(dirname "$destination_path")" "$source_path"
      )"
      ln -s "$relative_source" "$destination_path"
    fi
  done < <(find "$former_git_dir" -mindepth 1 -print0)

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

  if [[ "$(realpath -m "$config_path")" != "$former_stow_path" ]]; then
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

if [[ "$install_sway" == "true" ]]; then
  sway_dir="$XDG_CONFIG_HOME/sway"
  ensure_dir "$sway_dir"

  if [[ ! -e "$sway_dir/local.conf" ]]; then
    {
      cat <<'EOF'
# Machine-local output configuration. This file is intentionally untracked.
# Discover output names with: swaymsg -t get_outputs
#
# Examples:
# output eDP-1 scale 1.5
# output DP-1 position 0 0
# output HDMI-A-1 position 2560 0
EOF
      if [[ "$hardware_model" == "ga402xz" ]]; then
        cat <<'EOF'

# The GA402XZ panel is intentionally used without HiDPI scaling.
output eDP-1 scale 1
EOF
      fi
    } | atomic_write_file "$sway_dir/local.conf"
    info "Created local Sway output override: $sway_dir/local.conf"
  else
    info "Keeping existing local Sway output override: $sway_dir/local.conf"
  fi
fi

# Identity files are intentionally local. Migrate links created by older
# versions of this repository before Stow runs, then keep the files outside
# the Stow package.
migrate_stow_managed_git_config "local"
migrate_stow_managed_git_config "drdk"

success "Machine-local configuration initialized"
