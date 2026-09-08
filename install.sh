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
fedora | fedora-wsl | macos | parrot-ctf)
  ;;
*)
  printf 'ERROR: Unsupported platform: %s (expected fedora, fedora-wsl, macos, or parrot-ctf)\n' \
    "$platform" >&2
  exit 1
  ;;
esac

for forwarded_arg in "${forwarded_args[@]}"; do
  if [[ "$forwarded_arg" == "-h" || "$forwarded_arg" == "--help" ]]; then
    cat <<EOF
Usage: ./install.sh [--platform fedora|fedora-wsl|macos|parrot-ctf] [options]

  --platform NAME    Target platform: fedora (default), fedora-wsl, macos,
                     or parrot-ctf. Selects which platforms/NAME/install.sh
                     runs; all other options below are that platform's own
                     and are simply forwarded to it.

Options for platform '$platform' (pass --platform to see another
platform's options):

EOF
    break
  fi
done

exec "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}"
