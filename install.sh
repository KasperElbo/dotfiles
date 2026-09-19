#!/bin/bash

# Compatibility entry point. Keep this file within Apple's Bash 3.2 syntax:
# the real installer starts only after the macOS bootstrap has found or
# established the repository's supported Bash.
set -e

repo_root="$(cd "$(dirname "$0")" && pwd)"
platform="fedora"
platform_explicit="false"
rerun="false"
expect_platform="false"

# Inspect only the platform selector and --rerun. Do not shift or rebuild "$@":
# the exact original argument vector is forwarded across the interpreter
# boundary.
for argument in "$@"; do
  if [ "$expect_platform" = "true" ]; then
    if [ -z "$argument" ]; then
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    fi
    platform="$argument"
    platform_explicit="true"
    expect_platform="false"
    continue
  fi

  case "$argument" in
    --platform)
      expect_platform="true"
      ;;
    --platform=*)
      platform="${argument#*=}"
      platform_explicit="true"
      if [ -z "$platform" ]; then
        printf 'ERROR: --platform requires a value\n' >&2
        exit 1
      fi
      ;;
    --rerun)
      rerun="true"
      ;;
  esac
done

if [ "$expect_platform" = "true" ]; then
  printf 'ERROR: --platform requires a value\n' >&2
  exit 1
fi

# A --rerun that names no platform must still reach the interpreter its
# remembered platform needs, so read just the recorded platform name here. The
# authoritative reading, validation and reconstruction of the remembered
# configuration belong to scripts/install-main.sh; this only chooses a boot
# path, and only for a name the repository actually provides.
if [ "$rerun" = "true" ] && [ "$platform_explicit" = "false" ]; then
  install_state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/install.conf"
  if [ -r "$install_state" ]; then
    remembered_platform="$(awk -F= \
      '$1 == "last_successful_platform" { print $2; exit }' "$install_state")"
    # The supported names live in config/capabilities.tsv, as its implemented
    # base rows that this repository has an installer script for. Asking the
    # manifest here keeps this guard from drifting away from the list
    # scripts/install-main.sh validates against, and requiring the script keeps
    # both from accepting a platform installed by something other than Bash
    # (the Windows host, installed by platforms/windows/install.ps1). Columns
    # are found by name in the header, as common/lib/manifest.sh does; this
    # entry point runs before a supported Bash exists, so it cannot source it.
    if [ -n "$remembered_platform" ] &&
      [ -f "$repo_root/platforms/$remembered_platform/install.sh" ] &&
      awk -F '\t' -v p="$remembered_platform" \
      'NR == 1 { for (i = 1; i <= NF; i++) column[$i] = i; next }
       column["capability"] && column["platform"] && column["status"] &&
       $column["capability"] == "base" && $column["platform"] == p &&
       $column["status"] == "implemented" { found = 1 }
       END { exit !found }' "$repo_root/config/capabilities.tsv" 2>/dev/null; then
      platform="$remembered_platform"
    fi
  fi
fi

if [ "$platform" = "macos" ]; then
  exec /bin/bash "$repo_root/scripts/bootstrap-macos.sh" "$@"
fi

exec "${BASH:-/bin/bash}" "$repo_root/scripts/install-main.sh" "$@"
