#!/usr/bin/env bash

preflight_writable_path() {
  local path="$1"
  local probe="$path"
  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || { printf 'Path is not writable: %s\n' "$path" >&2; return 1; }
}

preflight_commands() {
  local command missing=0
  for command in "$@"; do
    command_exists "$command" || { printf 'Missing preflight command: %s\n' "$command" >&2; missing=1; }
  done
  ((missing == 0))
}

preflight_stow_packages() {
  local spec package_root package source relative target resolved parent conflict_type
  local conflicts=0
  for spec in "$@"; do
    package_root="${spec%%::*}"; package="${spec#*::}"
    [[ -d "$package_root/$package" ]] || {
      printf 'Stow package is missing: %s (%s)\n' "$package" "$package_root" >&2
      conflicts=$((conflicts + 1)); continue
    }
    while IFS= read -r -d '' source; do
      relative="${source#"$package_root/$package/"}"
      target="$HOME/$relative"
      parent="$(dirname "$target")"
      while [[ "$parent" != "$HOME" && "$parent" == "$HOME/"* ]]; do
        if [[ -e "$parent" && ! -d "$parent" ]] || [[ -L "$parent" ]]; then
          printf 'Stow conflict [%s]: parent path is not a real directory: %s\n' "$package" "$parent" >&2
          conflicts=$((conflicts + 1)); break
        fi
        parent="$(dirname "$parent")"
      done
      if [[ -L "$target" ]]; then
        resolved="$(resolve_symlink_target "$target" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then conflict_type='dangling link'
        elif [[ "$resolved" == "$source" ]]; then continue
        elif [[ "$resolved" == "$DOTFILES_ROOT/"* ]]; then conflict_type='link to another package in this checkout'
        else conflict_type='link owned by another checkout or source'
        fi
        printf 'Stow conflict [%s]: %s: %s\n' "$package" "$conflict_type" "$target" >&2
        conflicts=$((conflicts + 1))
      elif [[ -e "$target" ]]; then
        printf 'Stow conflict [%s]: existing file or directory: %s\n' "$package" "$target" >&2
        conflicts=$((conflicts + 1))
      fi
    done < <(find "$package_root/$package" \( -type f -o -type l \) -print0)
  done
  if ((conflicts > 0)); then
    printf '%d Stow conflict(s) found. Move or back up these paths; --adopt is never automatic.\n' "$conflicts" >&2
    return 1
  fi
}
