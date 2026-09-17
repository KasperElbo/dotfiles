#!/usr/bin/env bash

# Pre-mutation checks shared by the platform installers and the Stow scripts.
#
# Each check prints a specific message to stderr and returns 1, so a preflight
# function under errexit refuses at the first failure, before anything changes.
# This library deliberately does not select shell options. It needs
# DOTFILES_ROOT and command_exists from lib/common.sh and the command-provider
# reader from lib/capabilities.sh, and sources both itself, so it is correct
# however the caller was set up.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
# shellcheck source=capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/capabilities.sh"

preflight_writable_path() {
  local path="$1"
  local probe="$path"
  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || { printf 'Path is not writable: %s\n' "$path" >&2; return 1; }
}

preflight_platform_command_providers() {
  local platform="$1"
  local command provider classification missing=0
  local command_specs

  command_specs="$(capability_preflight_command_specs "$platform")" || return 1
  # Fail closed: an empty specification means the platform key does not match
  # the manifest, which would silently skip every pre-mutation check.
  [[ -n "$command_specs" ]] || {
    printf 'No preflight command specification for platform: %s\n' "$platform" >&2
    return 1
  }
  while IFS=$'\t' read -r command provider classification; do
    command_exists "$command" || {
      printf 'Missing %s command: %s (provider: %s)\n' \
        "$classification" "$command" "$provider" >&2
      missing=1
    }
  done <<<"$command_specs"

  ((missing == 0))
}

# preflight_stow_packages [--replaces <target>]... <package-root>::<package>...
#
# Refuse when any path a package would link is already taken. A --replaces
# target is a link the caller removes itself before stowing, such as one an
# earlier layout of this checkout left behind, and is not a conflict.
preflight_stow_packages() {
  local spec package_root package source relative target resolved parent conflict_type
  local candidate is_replaced
  local conflict_count=0
  local -a replaces=()
  while [[ "${1:-}" == --replaces ]]; do
    replaces+=("$2")
    shift 2
  done
  for spec in "$@"; do
    package_root="${spec%%::*}"; package="${spec#*::}"
    [[ -d "$package_root/$package" ]] || {
      printf 'Stow package is missing: %s (%s)\n' "$package" "$package_root" >&2
      conflict_count=$((conflict_count + 1)); continue
    }
    while IFS= read -r -d '' source; do
      relative="${source#"$package_root/$package/"}"
      target="$HOME/$relative"
      parent="$(dirname "$target")"
      while [[ "$parent" != "$HOME" && "$parent" == "$HOME/"* ]]; do
        if [[ -e "$parent" && ! -d "$parent" ]] || [[ -L "$parent" ]]; then
          printf 'Stow conflict [%s]: parent path is not a real directory: %s\n' "$package" "$parent" >&2
          conflict_count=$((conflict_count + 1)); break
        fi
        parent="$(dirname "$parent")"
      done
      is_replaced=false
      for candidate in ${replaces[@]+"${replaces[@]}"}; do
        [[ "$candidate" != "$target" ]] || is_replaced=true
      done
      if [[ "$is_replaced" == true ]]; then
        continue
      elif [[ -L "$target" ]]; then
        resolved="$(resolve_symlink_target "$target" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then conflict_type='dangling link'
        elif [[ "$resolved" == "$source" ]]; then continue
        elif [[ "$resolved" == "$DOTFILES_ROOT/"* ]]; then conflict_type='link to another package in this checkout'
        else conflict_type='link owned by another checkout or source'
        fi
        printf 'Stow conflict [%s]: %s: %s\n' "$package" "$conflict_type" "$target" >&2
        conflict_count=$((conflict_count + 1))
      elif [[ -e "$target" ]]; then
        printf 'Stow conflict [%s]: existing file or directory: %s\n' "$package" "$target" >&2
        conflict_count=$((conflict_count + 1))
      fi
    done < <(find "$package_root/$package" \( -type f -o -type l \) -print0)
  done
  if ((conflict_count > 0)); then
    printf '%d Stow conflict(s) found. Move or back up these paths; --adopt is never automatic.\n' "$conflict_count" >&2
    return 1
  fi
}
