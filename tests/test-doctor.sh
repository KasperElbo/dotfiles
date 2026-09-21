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

# Which schema a component state file must declare comes from the selected
# capability's row in config/capabilities.tsv, not from the file's own
# `profile=` key (#342, REA-06). Doctor used to read that key and hand it back
# as the profile to expect, which proved the record agreed with itself and said
# nothing about whose state it was.
lifecycle_state() {
  local platform="$1" capabilities="$2"
  rm -f "$XDG_CONFIG_HOME"/dotfiles/*.conf
  profile_state_write "$state" install installed "platform=$platform" \
    "requested_capabilities=$capabilities" "observed_capabilities=$capabilities" \
    external_assurance=not-recorded repository=local-checkout \
    "revision=$revision" "provenance=capability-manifest@$revision" \
    started_at=2026-09-13T00:00:00Z finished_at=2026-09-13T00:10:00Z
}

expect_doctor_accepts() {
  local description="$1" log="$test_root/accept.log"
  if ! "$repo_root/doctor" >"$log" 2>&1; then
    printf 'Doctor rejected %s:\n' "$description" >&2
    cat "$log" >&2
    exit 1
  fi
}

expect_doctor_rejects() {
  local description="$1" expected="$2" log="$test_root/reject.log"
  if "$repo_root/doctor" >"$log" 2>&1; then
    printf 'Doctor accepted %s:\n' "$description" >&2
    cat "$log" >&2
    exit 1
  fi
  grep -Fq "$expected" "$log" || {
    printf 'Doctor rejected %s, but not for the expected reason.\n' "$description" >&2
    printf 'Expected: %s\n' "$expected" >&2
    cat "$log" >&2
    exit 1
  }
}

# One complete, valid record per schema the registry names, written through the
# same library the installers use. A doctor that rejected everything would pass
# every negative assertion below, so each mapping the registry declares is
# first shown to pass -- and the coverage check underneath means a new
# capability cannot add a state file this suite silently skips.
write_state_fixture() {
  local schema="$1" path="$XDG_CONFIG_HOME/dotfiles/$2.conf"
  case "$schema" in
  ai) profile_state_write "$path" ai installed claude_code=2.0.1 herdr=0.4.0 \
    codex=0.3.0 firstmate=0.2.0 ;;
  ocaml) profile_state_write "$path" ocaml installed switch=5.2.0 compiler=5.2.0 ;;
  containers) profile_state_write "$path" containers installed runtime=podman \
    mode=rootless api_socket=enabled ;;
  podman-machine) profile_state_write "$path" podman-machine installed rootful=false ;;
  dictation) profile_state_write "$path" dictation installed application=handy \
    provider=upstream-rpm version=0.5.0 ;;
  desktop-tools) profile_state_write "$path" desktop-tools installed \
    image_viewer=gwenview image_editor=gimp pdf_viewer=okular pdf_tool=qpdf ;;
  hardening) profile_state_write "$path" hardening installed \
    selinux_mode=enforcing faillock=enabled auditd=enabled ;;
  tailscale) profile_state_write "$path" tailscale installed variant=standalone-app ;;
  vm-guest) profile_state_write "$path" vm-guest installed hypervisor=kvm \
    guest_agent=qemu-guest-agent network=bridged ;;
  vm-host) profile_state_write "$path" vm-host installed backend=libvirt \
    libvirt_uri=qemu:///system network=default storage_pool=default ;;
  parrot-ctf) profile_state_write "$path" parrot-ctf installed hypervisor=kvm \
    network=nat host_secrets=excluded security_tools=image ;;
  ga402xz | ga402rk) profile_state_write "$path" "$schema" installed \
    secure_boot=true charge_limit=80 ;;
  *) return 1 ;;
  esac
}

# The registry's own list of component state files, read by column name.
state_rows() {
  awk -F '\t' 'NR == 1 {
      for (i = 1; i <= NF; i++) column[$i] = i
      for (name in required) if (!(name in column)) missing = missing " " name
      next
    }
    $column["status"] != "implemented" { next }
    $column["state"] == "-" || $column["state"] == "install" { next }
    { print $column["capability"] "\t" $column["platform"] "\t" \
        $column["state"] "\t" $column["state_profile"] }' \
    "$repo_root/config/capabilities.tsv"
}

rows="$(state_rows)"
[[ -n "$rows" ]] ||
  { printf 'No component state rows were read from the capability registry.\n' >&2; exit 1; }
while IFS=$'\t' read -r capability platform state_id schemas; do
  IFS=, read -r -a accepted <<<"$schemas"
  for schema in "${accepted[@]}"; do
    lifecycle_state "$platform" "base,$capability"
    write_state_fixture "$schema" "$state_id" || {
      printf 'This suite has no valid record for the %s schema, which %s/%s declares.\n' \
        "$schema" "$platform" "$capability" >&2
      printf 'Add one to write_state_fixture; a mapping no case covers is untested.\n' >&2
      exit 1
    }
    expect_doctor_accepts "$platform/$capability state written as $schema in $state_id.conf"
  done
done <<<"$rows"

# Every legitimate mapping where the file name and the schema differ has to be
# among those, or the loop above proves less than it appears to.
for pair in 'macos-containers	podman-machine' 'macos-tailscale	tailscale' \
  'macos-dictation	dictation' 'hardware	ga402xz,ga402rk'; do
  IFS=$'\t' read -r wanted_state wanted_schema <<<"$pair"
  grep -Fq "	$wanted_state	$wanted_schema" <<<"$rows" || {
    printf 'The registry no longer maps %s to %s; this suite asserts mappings that have moved.\n' \
      "$wanted_state" "$wanted_schema" >&2
    printf '%s\n' "$rows" >&2
    exit 1
  }
done

# The audit's own reproduction: Fedora selected containers, and containers.conf
# held a complete, valid OCaml record.
lifecycle_state fedora base,containers
profile_state_write "$XDG_CONFIG_HOME/dotfiles/containers.conf" ocaml installed \
  switch=5.2.0 compiler=5.2.0
expect_doctor_rejects 'an OCaml record in the container state file' \
  "Enabled capability 'containers' has state for profile 'ocaml', not containers"

# The same capability on the other platform, which is the case a file name
# alone cannot catch: a valid record of Fedora's container schema, in the file
# macOS really does keep its container state in.
lifecycle_state macos base,containers
profile_state_write "$XDG_CONFIG_HOME/dotfiles/macos-containers.conf" \
  containers installed runtime=podman mode=rootless api_socket=enabled
expect_doctor_rejects "Fedora's container record in the macOS container state file" \
  "Enabled capability 'containers' has state for profile 'containers', not podman-machine"

# A state file the registry gives two schemas still accepts only those two.
lifecycle_state fedora base,hardware
profile_state_write "$XDG_CONFIG_HOME/dotfiles/hardware.conf" hardening installed \
  selinux_mode=enforcing faillock=enabled auditd=enabled
expect_doctor_rejects 'a hardening record in the ASUS hardware state file' \
  "Enabled capability 'hardware' has state for profile 'hardening', not ga402xz or ga402rk"

# A profile no schema answers to is rejected by the same comparison rather than
# reaching the state validator and being reported as an unknown profile there.
lifecycle_state fedora base,containers
printf 'schema_version=2\nprofile=nonsense\nstatus=installed\n' \
  >"$XDG_CONFIG_HOME/dotfiles/containers.conf"
expect_doctor_rejects 'a state file naming a profile no schema declares' \
  "Enabled capability 'containers' has state for profile 'nonsense', not containers"

# A file that names the right schema and does not satisfy it is corrupt, which
# is a different finding from the wrong schema and has to stay one.
lifecycle_state fedora base,containers
profile_state_write "$XDG_CONFIG_HOME/dotfiles/containers.conf" containers installed \
  runtime=podman mode=rootless api_socket=enabled
grep -v '^runtime=' "$XDG_CONFIG_HOME/dotfiles/containers.conf" \
  >"$test_root/containers.trimmed"
mv "$test_root/containers.trimmed" "$XDG_CONFIG_HOME/dotfiles/containers.conf"
expect_doctor_rejects 'a container record missing a required key' \
  "Enabled capability 'containers' has corrupt state"

# Missing state for a selected capability stays a failure, and state for a
# capability the installation did not select stays a warning: doctor reports
# residual files, it does not own removing them.
lifecycle_state fedora base,containers
expect_doctor_rejects 'a selected capability with no state file at all' \
  "Enabled capability 'containers' is missing state"

lifecycle_state fedora base,containers
write_state_fixture containers containers
write_state_fixture hardening hardening
residual_log="$test_root/residual.log"
if ! "$repo_root/doctor" >"$residual_log" 2>&1; then
  printf 'Doctor failed on unselected leftover state, which is a warning:\n' >&2
  cat "$residual_log" >&2
  exit 1
fi
grep -Fq 'Residual state is no longer owned by the installed selection' "$residual_log" || {
  printf 'Doctor did not report the unselected hardening state as residual:\n' >&2
  cat "$residual_log" >&2
  exit 1
}

rm -f "$XDG_CONFIG_HOME"/dotfiles/*.conf

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

printf 'Doctor lifecycle, state-schema ownership and hardware checks passed.\n'