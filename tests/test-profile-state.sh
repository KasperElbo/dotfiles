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

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

profile_state_write "$state" ocaml installed switch=dotfiles-ocaml-5.5.0 compiler=5.5.0
[[ "$(file_mode "$state")" == 600 ]]
[[ "$(profile_state_read "$state" compiler ocaml)" == 5.5.0 ]]
first="$(cksum "$state")"
profile_state_write "$state" ocaml installed switch=dotfiles-ocaml-5.5.0 compiler=5.5.0
[[ "$(cksum "$state")" == "$first" ]]

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

# Reproduce the lifecycle state shape written before the first installer step.
# This specifically guards the first-key duplicate check against Bash 3.2's
# nounset behavior for initialized-but-empty arrays.
install_state="$test_root/install.conf"
profile_state_write "$install_state" install applying \
  platform=macos \
  requested_capabilities=base \
  observed_capabilities=pending \
  external_assurance=not-recorded \
  repository=local-checkout \
  revision=test \
  provenance=capability-manifest@test \
  started_at=2026-09-14T00:00:00Z \
  rerun=install.sh
profile_state_validate_file "$install_state" install

# The checkout's git remote is recorded verbatim. Real remotes use characters
# the generic charset refuses, and refusing one used to abort a fresh install
# before any package was touched.
for remote in 'git@host:~user/repo.git' 'ssh://git@host/~/repo.git' \
  'https://user@dev.azure.com/o/p/_git/r' 'git@github.com:KasperElbo/dotfiles.git'; do
  profile_state_validate_value repository "$remote" || {
    printf 'Valid git remote rejected as a repository value: %s\n' "$remote" >&2; exit 1
  }
done
for invalid in $'git@host:repo.git\nstatus=installed' 'https://host/repo.git?ref=main'; do
  if profile_state_validate_value repository "$invalid"; then
    printf 'Repository value that breaks the state format passed: %s\n' "$invalid" >&2; exit 1
  fi
done

remote_checkout="$test_root/remote-checkout"
git init -q "$remote_checkout"
git -C "$remote_checkout" -c user.name=Test -c user.email=test@example.com \
  -c commit.gpgsign=false commit -q --allow-empty -m 'scratch checkout'
git -C "$remote_checkout" remote add origin 'git@host:~user/repo.git'
(
  # shellcheck source=../common/lib/install-lifecycle.sh
  source "$repo_root/common/lib/install-lifecycle.sh"
  export HOME="$test_root/lifecycle-home"
  export XDG_STATE_HOME="$test_root/lifecycle-state"
  DOTFILES_ROOT="$remote_checkout"
  install_lifecycle_begin fedora base './install.sh --non-interactive'
  [[ "$(profile_state_read "$(install_state_path)" repository install)" == 'git@host:~user/repo.git' ]]
)

printf 'Versioned profile-state validation and migration passed.\n'
