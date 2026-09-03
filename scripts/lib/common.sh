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

ensure_dir() {
  mkdir -p "$1"
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
