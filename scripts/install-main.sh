#!/usr/bin/env bash

# This is the modern-Bash boundary. The compatibility entry point has already
# had an opportunity to establish Homebrew Bash before this guard runs.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ERROR: The real installer requires Bash 4.4 or newer (found %s).\n' \
    "$BASH_VERSION" >&2
  printf 'On macOS, start through ./install.sh --platform macos so the compatibility bootstrap can locate or install Homebrew Bash.\n' >&2
  exit 2
fi

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == doctor ]]; then
  shift
  exec "$BASH" "$repo_root/scripts/doctor.sh" "$@"
fi

platform="fedora"
forwarded_args=()

while (($#)); do
  case "$1" in
  --platform)
    [[ $# -ge 2 ]] || {
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    }
    platform="$2"
    shift 2
    ;;
  --platform=*)
    platform="${1#*=}"
    [[ -n "$platform" ]] || {
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    }
    shift
    ;;
  *)
    forwarded_args+=("$1")
    shift
    ;;
  esac
done

supported_platforms="$(awk -F '\t' 'NR > 1 && $1 == "base" && $15 == "implemented" {print $2}' \
  "$repo_root/config/capabilities.tsv" | sort -u | paste -sd'|' -)"
if ! awk -F '\t' -v platform="$platform" \
  'NR > 1 && $1 == "base" && $2 == platform && $15 == "implemented" {found=1} END {exit !found}' \
  "$repo_root/config/capabilities.tsv"; then
  printf 'ERROR: Unsupported platform: %s (expected one of %s)\n' \
    "$platform" "$supported_platforms" >&2
  exit 1
fi

print_platform_options() {
  local line
  local options_seen="false"

  while IFS= read -r line; do
    if [[ "$options_seen" == "true" ]]; then
      printf '%s\n' "$line"
    elif [[ "$line" == "Options:" ]]; then
      options_seen="true"
    fi
  done

  if [[ "$options_seen" != "true" ]]; then
    printf 'ERROR: Platform help did not contain an Options section.\n' >&2
    return 1
  fi
}

for forwarded_arg in "${forwarded_args[@]}"; do
  if [[ "$forwarded_arg" == "-h" || "$forwarded_arg" == "--help" ]]; then
    cat <<EOF
Usage: ./install.sh [--platform NAME|--platform=NAME] [options]
       ./install.sh doctor

Options (platform '$platform'):
  --platform NAME    Target platform: fedora (default), fedora-wsl, macos,
                     or parrot-ctf. Selects which platforms/NAME/install.sh
                     runs; all other options below are that platform's own
                     and are simply forwarded to it.
EOF
    "$BASH" "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}" |
      print_platform_options
    exit 0
  fi
done

exec "$BASH" "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}"
