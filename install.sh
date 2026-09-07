#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
  *)
    forwarded_args+=("$1")
    shift
    ;;
  esac
done

case "$platform" in
fedora | fedora-wsl | parrot-ctf)
  ;;
*)
  printf 'ERROR: Unsupported platform: %s (expected fedora, fedora-wsl, or parrot-ctf)\n' \
    "$platform" >&2
  exit 1
  ;;
esac

exec "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}"
