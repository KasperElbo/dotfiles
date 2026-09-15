#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/verify.sh
source "$repo_root/common/lib/verify.sh"

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

root_path="$(resolve_existing_path /)" || fail_test "could not canonicalize /"
[[ "$root_path" == / ]] ||
  fail_test "root canonicalized to '$root_path'; expected '/'"

usr_path="$(resolve_existing_path /usr)" || fail_test "could not canonicalize /usr"
[[ "$usr_path" == /usr ]] ||
  fail_test "/usr canonicalized to '$usr_path'; expected '/usr'"

verify_path_is_within_root /usr/bin/opam "$usr_path" ||
  fail_test "/usr/bin/opam was not recognized as inside canonical /usr"

printf 'PASS: root-level canonical paths use a single leading slash\n'
