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
printf 'Atomic lifecycle commit, stable rerun, and failure state passed.\n'
