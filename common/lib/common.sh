#!/usr/bin/env bash

set -euo pipefail

# Shared library value consumed by sourcing scripts.
# shellcheck disable=SC2034
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

info() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m==>\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prepend_path() {
  local entry="$1"
  local current
  local rebuilt=""
  local -a path_entries=()

  [[ -n "$entry" ]] || return 0

  IFS=: read -r -a path_entries <<<"${PATH:-}"
  for current in "${path_entries[@]}"; do
    [[ -n "$current" && "$current" != "$entry" ]] || continue
    rebuilt="${rebuilt:+$rebuilt:}$current"
  done

  PATH="$entry${rebuilt:+:$rebuilt}"
  export PATH
}

resolve_mise_command() {
  local candidate

  # The standalone Linux installer has a fixed, user-owned location. Prefer
  # it before inherited PATH so a stale WSL process cannot select mise.exe.
  if [[ -x "$HOME/.local/bin/mise" ]]; then
    printf '%s\n' "$HOME/.local/bin/mise"
  else
    candidate="$(command -v mise 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
    else
      return 1
    fi
  fi
}

# Establish the non-interactive equivalent of the user-tool portion of the
# final Zsh environment. Installers must not rely on the shell which launched
# them having sourced .zshenv/.zshrc (notably, a WSL terminal may still be the
# Bash process from before ensure_zsh_login_shell changed the account).
establish_user_tool_environment() {
  local mise_data_dir
  local mise_shims_dir

  mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
  mise_shims_dir="${MISE_SHIMS_DIR:-$mise_data_dir/shims}"

  prepend_path "$HOME/.local/bin"
  prepend_path "$mise_shims_dir"
  hash -r 2>/dev/null || true
}

ensure_dir() {
  mkdir -p "$1"
}

resolve_symlink_target() {
  local path="$1"
  local target
  local target_dir

  target="$(readlink "$path")" || return 1

  if [[ "$target" != /* ]]; then
    target="$(dirname "$path")/$target"
  fi

  target_dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}

atomic_write_file() {
  local path="$1"
  local temporary

  [[ ! -d "$path" ]] || die "Cannot replace directory with file: $path"

  temporary="$(mktemp "${path}.XXXXXX")"

  if ! cat >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  chmod 600 "$temporary"

  if ! mv -- "$temporary" "$path"; then
    rm -f -- "$temporary"
    return 1
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local answer

  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n] " answer
    answer="${answer:-y}"
  else
    read -r -p "$prompt [y/N] " answer
    answer="${answer:-n}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

require_command() {
  command_exists "$1" || die "Required command not found: $1"
}

login_shell_for_user() {
  local user="$1"
  local passwd_entry

  passwd_entry="$(getent passwd "$user")" || return 1
  printf '%s\n' "${passwd_entry##*:}"
}

resolve_zsh_path() {
  local zsh_path

  zsh_path="$(command -v zsh 2>/dev/null)" || return 1
  [[ "$zsh_path" == /* && -f "$zsh_path" && -x "$zsh_path" ]] || return 1
  printf '%s\n' "$zsh_path"
}

shell_paths_match() {
  local first="$1"
  local second="$2"

  [[ -n "$first" && -n "$second" ]] || return 1
  [[ "$first" == "$second" ]] ||
    [[ -e "$first" && -e "$second" && "$first" -ef "$second" ]]
}

ensure_zsh_login_shell() {
  local current_user
  local current_shell
  local zsh_path

  export ZSH_LOGIN_SHELL_CHANGED="false"

  [[ "$(id -u)" -ne 0 ]] ||
    die "Refusing to change root's login shell; run the installer as a regular user."

  current_user="$(id -un)" || die "Could not determine the invoking user."
  current_shell="$(login_shell_for_user "$current_user")" ||
    die "Could not determine the login shell for $current_user."
  zsh_path="$(resolve_zsh_path)" || die "Could not resolve an installed Zsh executable."

  if shell_paths_match "$current_shell" "$zsh_path"; then
    info "Zsh is already the default login shell"
  else
    info "Setting Zsh as the default login shell"
    sudo usermod --shell "$zsh_path" "$current_user"
    export ZSH_LOGIN_SHELL_CHANGED="true"
  fi
}
