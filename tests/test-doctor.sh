#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"
test_root="$(mktemp -d)"; trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
state="$XDG_STATE_HOME/dotfiles/install.conf"
revision="$(git -C "$repo_root" rev-parse HEAD)"
profile_state_write "$state" install applying platform=fedora \
  requested_capabilities=base,ocaml observed_capabilities=pending \
  external_assurance=not-recorded repository=local-checkout \
  "revision=$revision" "provenance=capability-manifest@$revision" \
  started_at=2026-09-13T00:00:00Z rerun=./install.sh
if "$repo_root/doctor" >"$test_root/doctor.log" 2>&1; then
  printf 'Doctor accepted an interrupted installation.\n' >&2; exit 1
fi
grep -Fq 'Last installation is applying' "$test_root/doctor.log"
grep -Fq "Enabled capability 'ocaml' is missing state" "$test_root/doctor.log"

printf 'schema_version=999\nprofile=install\nstatus=installed\n' >"$state"
if "$repo_root/doctor" >"$test_root/corrupt.log" 2>&1; then
  printf 'Doctor accepted corrupt state.\n' >&2; exit 1
fi
grep -Fq 'Lifecycle state is corrupt' "$test_root/corrupt.log"
printf 'Doctor interrupted/corrupt lifecycle checks passed.\n'
