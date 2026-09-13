#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
state="$test_root/state.conf"

profile_state_write "$state" ocaml installed switch=dotfiles-ocaml-5.5.0 compiler=5.5.0
[[ "$(stat -c '%a' "$state")" == 600 ]]
[[ "$(profile_state_read "$state" compiler ocaml)" == 5.5.0 ]]
first="$(sha256sum "$state")"
profile_state_write "$state" ocaml installed switch=dotfiles-ocaml-5.5.0 compiler=5.5.0
[[ "$(sha256sum "$state")" == "$first" ]]

for invalid in \
  $'profile=ocaml\nswitch=x\ncompiler=5.5.0\ncompiler=5.4.0' \
  $'profile=ocaml\nswitch=x\ncompiler=5.5.0\nunknown=x' \
  $'schema_version=2\nprofile=ocaml\nstatus=installed\nswitch=x' \
  $'schema_version=2\nprofile=not-a-profile\nstatus=installed'; do
  printf '%s\n' "$invalid" >"$state"
  if profile_state_validate_file "$state" ocaml >/dev/null 2>&1; then
    printf 'Invalid state unexpectedly passed validation.\n' >&2; exit 1
  fi
done

printf 'profile=ocaml\nswitch=dotfiles-ocaml-5.4.0\ncompiler=5.4.0\n' >"$state"
[[ "$(profile_state_read "$state" compiler ocaml)" == 5.4.0 ]]
profile_state_write "$state" ocaml installed switch=dotfiles-ocaml-5.4.0 compiler=5.4.0
grep -Fqx 'schema_version=2' "$state"
printf 'Versioned profile-state validation and migration passed.\n'
