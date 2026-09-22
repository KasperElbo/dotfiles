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

# resolve_existing_path and canonical_path_spelling are compared against each
# other at runtime: resolved_link_matches puts one on each side of a string
# equality, and the Stow preflight compares a resolved link, a resolved source
# and a resolved DOTFILES_ROOT prefix. So the two must never be independently
# specified -- a divergence would surface as a correctly stowed link reading as
# owned by another checkout, in the verifier and the preflight rather than in
# whichever spelling rule changed (issue #384, NC-03).
assert_same_spelling() {
  local path="$1"
  local resolved spelled

  resolved="$(resolve_existing_path "$path")" ||
    fail_test "resolve_existing_path could not canonicalize $path"
  spelled="$(canonical_path_spelling "$path")" ||
    fail_test "canonical_path_spelling could not canonicalize $path"
  [[ "$resolved" == "$spelled" ]] ||
    fail_test "the two spelling rules disagree about $path:" \
      "resolve_existing_path said '$resolved', canonical_path_spelling said '$spelled'"
  printf '%s\n' "$resolved"
}

[[ "$(assert_same_spelling /)" == / ]] ||
  fail_test "both spelling rules must print '/' for the root directory"

[[ "$(assert_same_spelling /usr)" == /usr ]] ||
  fail_test "both spelling rules must print '/usr', not '//usr'"

printf 'PASS: both spelling rules agree at the filesystem root\n'

# A path whose parent is reached through a symlink: the case where a rule that
# canonicalized the directory differently from its twin would first show up.
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/physical"
printf 'managed\n' >"$scratch/physical/file"
ln -s physical "$scratch/logical"

through_link="$(assert_same_spelling "$scratch/logical/file")"
[[ "$through_link" == "$(resolve_existing_path "$scratch/physical/file")" ]] ||
  fail_test "a file reached through a symlinked parent canonicalized to" \
    "'$through_link', not to its physical spelling"

printf 'PASS: both spelling rules agree through a symlinked parent directory\n'
