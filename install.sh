#!/bin/bash

# Compatibility entry point. Keep this file within Apple's Bash 3.2 syntax:
# the real installer starts only after the macOS bootstrap has found or
# established the repository's supported Bash.
set -e

repo_root="$(cd "$(dirname "$0")" && pwd)"
platform="fedora"
expect_platform="false"

# Inspect only the platform selector. Do not shift or rebuild "$@": the exact
# original argument vector is forwarded across the interpreter boundary.
for argument in "$@"; do
  if [ "$expect_platform" = "true" ]; then
    if [ -z "$argument" ]; then
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    fi
    platform="$argument"
    expect_platform="false"
    continue
  fi

  case "$argument" in
    --platform)
      expect_platform="true"
      ;;
    --platform=*)
      platform="${argument#*=}"
      if [ -z "$platform" ]; then
        printf 'ERROR: --platform requires a value\n' >&2
        exit 1
      fi
      ;;
  esac
done

if [ "$expect_platform" = "true" ]; then
  printf 'ERROR: --platform requires a value\n' >&2
  exit 1
fi

if [ "$platform" = "macos" ]; then
  exec /bin/bash "$repo_root/scripts/bootstrap-macos.sh" "$@"
fi

exec "${BASH:-/bin/bash}" "$repo_root/scripts/install-main.sh" "$@"
