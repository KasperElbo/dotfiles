#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"
test_root="$(mktemp -d)"; trap 'rm -rf -- "$test_root"' EXIT
export HOME="$test_root/home" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/dotfiles"
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

profile_state_write "$XDG_CONFIG_HOME/dotfiles/hardware.conf" ga402xz installed \
  secure_boot=true charge_limit=80
profile_state_write "$state" install installed platform=fedora \
  requested_capabilities=base,hardware observed_capabilities=base,hardware \
  external_assurance=not-recorded repository=local-checkout \
  "revision=$revision" "provenance=capability-manifest@$revision" \
  started_at=2026-09-13T00:00:00Z finished_at=2026-09-13T00:10:00Z \
  'rerun=./install.sh --platform fedora --hardware ga402xz --secure-boot --charge-limit 80 --non-interactive'
if ! "$repo_root/doctor" >"$test_root/hardware.log" 2>&1; then
  printf 'Doctor rejected a selected, valid hardware state:\n' >&2
  cat "$test_root/hardware.log" >&2
  exit 1
fi
grep -Fq 'Last installation completed (fedora: base,hardware).' \
  "$test_root/hardware.log"
if grep -Fq 'Residual state is no longer owned' "$test_root/hardware.log"; then
  printf 'Doctor treated selected hardware state as residual:\n' >&2
  cat "$test_root/hardware.log" >&2
  exit 1
fi

# A failed run names the step that stopped and points at commands this
# repository actually has (#225, DOC-037). It must never tell the user to
# "rerun the recorded command": no stored command text is ever executed, and
# --rerun has nothing to reapply from a failed run.
profile_state_write "$state" install failed platform=fedora \
  requested_capabilities=base,ocaml observed_capabilities=partial \
  external_assurance=not-recorded repository=local-checkout \
  "revision=$revision" "provenance=capability-manifest@$revision" \
  started_at=2026-09-13T00:00:00Z finished_at=2026-09-13T00:05:00Z \
  failed_step=ocaml completed_steps=system,stow pending_steps=verify \
  'rerun=./install.sh --platform fedora --ocaml --non-interactive'
if "$repo_root/doctor" >"$test_root/failed.log" 2>&1; then
  printf 'Doctor accepted a failed installation.\n' >&2; exit 1
fi
grep -Fq 'Last installation is failed at step [ocaml] (fedora).' "$test_root/failed.log"
grep -Fq 'Completed steps: system,stow' "$test_root/failed.log"
grep -Fq 'Pending steps:   verify' "$test_root/failed.log"
grep -Fq './install.sh --rerun --dry-run' "$test_root/failed.log"
if grep -Fq 'rerun the recorded command' "$test_root/failed.log"; then
  printf 'Doctor still tells the user to rerun the recorded command.\n' >&2; exit 1
fi
if grep -Fq -- '--platform fedora --ocaml --non-interactive' "$test_root/failed.log"; then
  printf 'Doctor printed the display-only recorded command as an instruction.\n' >&2; exit 1
fi

printf 'Doctor interrupted/corrupt lifecycle and hardware ownership checks passed.\n'