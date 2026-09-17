#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"; trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home" XDG_STATE_HOME="$test_root/state"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/install-lifecycle.sh
source "$repo_root/common/lib/install-lifecycle.sh"
mkdir -p "$HOME"

install_lifecycle_begin fedora base './install.sh --non-interactive'
[[ "$(profile_state_read "$(install_state_path)" status install)" == applying ]]
install_lifecycle_commit
state="$(install_state_path)"
[[ "$(profile_state_read "$state" status install)" == installed ]]
first="$(sha256sum "$state")"
install_lifecycle_begin fedora base './install.sh --non-interactive'
install_lifecycle_commit
[[ "$(sha256sum "$state")" == "$first" ]]

install_lifecycle_begin fedora base,ocaml './install.sh --ocaml --non-interactive'
install_lifecycle_failed ocaml system 'ocaml,verify'
[[ "$(profile_state_read "$state" status install)" == failed ]]
[[ "$(profile_state_read "$state" failed_step install)" == ocaml ]]

# A checkout's git remote is recorded verbatim. Real remotes use characters the
# generic state charset refuses, and refusing one used to abort a fresh install
# before any package was touched.
remote_checkout="$test_root/remote-checkout"
git init -q "$remote_checkout"
git -C "$remote_checkout" -c user.name=Test -c user.email=test@example.com \
  -c commit.gpgsign=false commit -q --allow-empty -m 'scratch checkout'
git -C "$remote_checkout" remote add origin 'git@host:~user/repo.git'
(
  export XDG_STATE_HOME="$test_root/remote-state"
  DOTFILES_ROOT="$remote_checkout"
  install_lifecycle_begin fedora base './install.sh --non-interactive'
  [[ "$(profile_state_read "$(install_state_path)" repository install)" == 'git@host:~user/repo.git' ]]
)

printf 'Atomic lifecycle commit, stable rerun, failure state, and remote recording passed.\n'
