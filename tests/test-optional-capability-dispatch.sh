#!/usr/bin/env bash
set -euo pipefail

# Optional-capability dispatch in the top-level platform verifiers (issue #344).
#
# Every platform verifier has a run of optional sections, one per capability a
# machine may or may not have asked for. Each used to be gated on its component
# state file alone, which made that file its own authority: with the file gone,
# the capability left the report entirely and nothing was said about it either
# way. A machine that selected --hardening and lost hardening.conf verified
# exactly like one that never selected hardening, and the AI section went
# further and printed a pass reading "not selected" on a machine that had
# selected it.
#
# Dispatch now reads the installation lifecycle record as well, so this suite
# covers both records against each other. Part 1 pins every cell of that matrix
# on the decision helper. Part 2 drives the five cases the issue names through
# the real Fedora verifier, which is the entry point the defect was found at.
# Part 3 holds the sibling verifiers to the same shape, and demonstrates on a
# scratch copy that it would notice the old one coming back.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
# git is not in the shared host list; the verifier reads the checkout's
# revision through it, and falls back to "unknown" when it is absent.
test_isolate_path git

test_new_root
root="$TEST_ROOT"
mapfile -t base_environment < <(test_env_args "$root")

# --- Fixture machines --------------------------------------------------------

# record_selection <capabilities>: a machine whose last installation recorded
# exactly these capabilities. Written where profile_state_dir reads it.
record_selection() {
  local capabilities="$1"

  mkdir -p "$root/state/dotfiles"
  cat >"$root/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=$capabilities
observed_capabilities=$capabilities
external_assurance=not-recorded
repository=local-checkout
revision=0123456789abcdef
provenance=capability-manifest@0123456789abcdef
EOF
}

forget_selection() {
  rm -f -- "$root/state/dotfiles/install.conf"
}

# The component state a completed install of each optional capability leaves
# behind, with the keys profile_state_required_keys demands of its profile.
# hardware.conf is the one whose profile names a machine model rather than the
# capability, which is why dispatch takes the profile name as an argument.
state_body() {
  case "$1" in
  hardware) printf 'profile=ga402xz\nsecure_boot=enabled\ncharge_limit=80\n' ;;
  vm-host) printf 'profile=vm-host\nbackend=libvirt\nlibvirt_uri=qemu:///system\nnetwork=default\nstorage_pool=default\n' ;;
  vm-guest) printf 'profile=vm-guest\nhypervisor=kvm\nguest_agent=qemu-guest-agent\nnetwork=virtio\n' ;;
  hardening) printf 'profile=hardening\nselinux_mode=enforcing\nfaillock=enabled\nauditd=enabled\n' ;;
  desktop-tools) printf 'profile=desktop-tools\nimage_viewer=loupe\nimage_editor=gimp\npdf_viewer=papers\npdf_tool=pdfarranger\n' ;;
  dictation) printf 'profile=dictation\napplication=handy\nprovider=upstream\nversion=0.6.0\n' ;;
  containers) printf 'profile=containers\nruntime=podman\nmode=rootless\napi_socket=enabled\n' ;;
  tailscale) printf 'profile=tailscale\nvariant=repo\n' ;;
  ai) printf 'profile=ai\nclaude_code=mise-npm\nherdr=mise-npm\ncodex=mise-npm\nfirstmate=absent\n' ;;
  *) return 1 ;;
  esac
}

state_path() {
  printf '%s/config/dotfiles/%s.conf\n' "$root" "$1"
}

write_state() {
  local capability="$1" path
  path="$(state_path "$capability")"
  mkdir -p "$(dirname "$path")"
  {
    printf 'schema_version=2\n'
    state_body "$capability"
    printf 'status=installed\n'
  } >"$path"
}

# A state file this checkout cannot read: the key is not one its profile allows.
corrupt_state() {
  local capability="$1" path
  path="$(state_path "$capability")"
  mkdir -p "$(dirname "$path")"
  {
    printf 'schema_version=2\n'
    state_body "$capability"
    printf 'status=installed\nnot_a_key_this_profile_allows=1\n'
  } >"$path"
}

remove_state() {
  rm -f -- "$(state_path "$1")"
}

# --- Part 1: the decision matrix --------------------------------------------
#
# The helper is asked directly, so each cell is one word rather than a verdict
# read out of a whole verifier's output.

disposition_of() {
  env "${base_environment[@]}" "DOTFILES_ROOT=$repo_root" bash -c '
    set -u
    source "$1/common/lib/common.sh"
    source "$1/common/lib/verify.sh"
    verify_optional_capability_disposition "$2" "$3" || true
  ' _ "$repo_root" "$1" "$2"
}

# The word, and the status that goes with it: the two dispositions that verify
# return 0 and the rest return non-zero, so a caller reading the status alone
# still cannot mistake a selected capability with no state for an absent one.
assert_disposition() {
  local expected="$1" platform="$2" capability="$3" actual status=0
  actual="$(disposition_of "$platform" "$capability")"
  assert_eq "$expected" "$actual" "disposition for $capability on $platform"
  disposition_status "$platform" "$capability" || status=$?
  case "$expected" in
  verify | leftover) assert_eq 0 "$status" "exit status for $expected" ;;
  *) [[ "$status" -ne 0 ]] ||
    _test_die "disposition $expected for $capability returned status 0" ;;
  esac
}

disposition_status() {
  env "${base_environment[@]}" "DOTFILES_ROOT=$repo_root" bash -c '
    set -u
    source "$1/common/lib/common.sh"
    source "$1/common/lib/verify.sh"
    verify_optional_capability_disposition "$2" "$3" >/dev/null
  ' _ "$repo_root" "$1" "$2"
}

record_selection base,hardening

remove_state hardening
assert_disposition missing fedora hardening

write_state hardening
assert_disposition verify fedora hardening

corrupt_state hardening
assert_disposition corrupt fedora hardening

record_selection base

remove_state hardening
assert_disposition absent fedora hardening

write_state hardening
assert_disposition leftover fedora hardening

corrupt_state hardening
assert_disposition corrupt fedora hardening

# A machine with no readable installation record must not have a selection
# invented for it. With nothing left behind it is reported exactly as an
# unselected machine is; with state present it is verified, which is what such
# a machine has always done.
forget_selection

remove_state hardening
assert_disposition absent fedora hardening

write_state hardening
assert_disposition verify fedora hardening

printf 'PASS: every cell of the selection/state matrix has its own disposition\n'

remove_state hardening

# What a state file may declare itself to be comes from the registry's
# state_profile column, not from the file. hardware.conf is the row that names
# two: its profile is the ASUS model, chosen from the machine's DMI identity at
# install time. A hardware.conf declaring anything else is a file this checkout
# cannot read, because a state file does not get to assert its own type.
record_selection base,hardware
write_state hardware
assert_disposition verify fedora hardware

{
  printf 'schema_version=2\n'
  state_body hardening
  printf 'status=installed\n'
} >"$(state_path hardware)"
assert_disposition corrupt fedora hardware
remove_state hardware

printf 'PASS: hardware.conf is accepted only as a model the registry names\n'

# A capability whose row records no state of its own cannot be dispatched from
# state, and saying nothing would be the defect this suite exists for. LaTeX on
# Fedora is such a row (state="-"): its selection is read straight from the
# lifecycle record by the verifier's own LaTeX section.
record_selection base,latex
assert_disposition unregistered fedora latex

printf 'PASS: a capability the registry records no state for is named, not skipped\n'

# --- Part 2: through the top-level platform verifiers ------------------------
#
# The entry points the defect was reported at. Each case below sets up one row
# of the issue's matrix for every optional capability at once and runs the
# verifier once, so the whole matrix costs five runs per platform rather than
# five per capability.

# capability|section label, in the order each verifier reports them. The AI
# profile is in neither list: its section keeps a scan for files the profile
# owns outside its own state, so its unselected and dispatched wordings differ,
# and it is asserted separately in every case.
fedora_capabilities=(
  'hardware|ASUS hardware'
  'vm-host|VM host'
  'vm-guest|VM guest'
  'hardening|Security hardening'
  'desktop-tools|Desktop tools'
  'dictation|Dictation'
  'containers|Containers (Podman)'
  'tailscale|Tailscale'
)
wsl_capabilities=(
  'containers|Containers (Podman)'
)

# run_verifier: the platform verifier named by $verifier_command, in the
# fixture machine. Its exit status says nothing useful -- the fixture satisfies
# almost nothing either verifier asks about -- so what each case asserts is the
# line its optional sections contributed. Reaching the summary is the guard
# that makes the negative assertions below worth something.
run_verifier() {
  local summary_line
  env "${base_environment[@]}" \
    ${verifier_environment[@]+"${verifier_environment[@]}"} \
    "$verifier_command" >"$root/verify.out" 2>&1 || true
  verifier_output="$(cat "$root/verify.out")"
  assert_contains "$verifier_output" "$verifier_summary"
  summary_line="$(grep -F "$verifier_summary" <<<"$verifier_output" | tail -n 1)"
  verifier_failures="$(sed -E 's/.*[^0-9]([0-9]+) failure\(s\).*/\1/' <<<"$summary_line")"
}

for_each_capability() {
  local entry capability label
  for entry in "${optional_capabilities[@]}"; do
    capability="${entry%%|*}"
    label="${entry#*|}"
    "$1" "$capability" "$label"
  done
}

assert_unselected() {
  local capability="$1" label="$2"
  assert_contains "$verifier_output" \
    "$label is not selected; its state and checks are not applicable"
  assert_not_contains "$verifier_output" "$label verification"
}

assert_selected_missing() {
  local capability="$1" label="$2"
  assert_contains "$verifier_output" \
    "$label is selected by this machine's recorded installation, but its profile state is missing ($(state_path "$capability"))"
  assert_not_contains "$verifier_output" \
    "$label is not selected; its state and checks are not applicable"
}

assert_selected_corrupt() {
  local capability="$1" label="$2"
  assert_contains "$verifier_output" \
    "$label is recorded on this machine, but this checkout cannot read its profile state ($(state_path "$capability"))"
}

assert_dispatched() {
  local capability="$1" label="$2"
  assert_contains "$verifier_output" "$label verification"
  assert_not_contains "$verifier_output" \
    "$label is selected by this machine's recorded installation, but its profile state is missing"
}

assert_leftover() {
  local capability="$1" label="$2"
  assert_contains "$verifier_output" \
    "$label is not selected by this machine's recorded installation, but its profile state remains ($(state_path "$capability"))"
  assert_contains "$verifier_output" "$label verification"
}

# exercise_matrix <platform>: the issue's five rows, for the verifier and
# capability list currently selected. The AI profile rides along in every case.
exercise_matrix() {
  local platform="$1" entry selected unselected_failures selected_failures expected
  local -a capabilities=(ai)

  for entry in "${optional_capabilities[@]}"; do capabilities+=("${entry%%|*}"); done
  selected="base,$(
    IFS=,
    printf '%s' "${capabilities[*]}"
  )"

  # Row 4: unselected, nothing left behind.
  record_selection base
  for_each_capability remove_state
  remove_state ai
  run_verifier
  for_each_capability assert_unselected
  assert_contains "$verifier_output" 'AI profile is not installed (not selected)'
  assert_not_contains "$verifier_output" 'AI profile verification'
  unselected_failures="$verifier_failures"
  printf 'PASS: %s reports every unselected capability, and dispatches none\n' "$platform"

  # Row 2: every capability selected, none of their state written. This is the
  # case the issue is about, and the one that used to be indistinguishable from
  # the row above.
  record_selection "$selected"
  run_verifier
  for_each_capability assert_selected_missing
  assert_contains "$verifier_output" \
    "AI profile is selected by this machine's recorded installation, but its profile state is missing ($(state_path ai))"
  assert_not_contains "$verifier_output" 'AI profile is not installed (not selected)'
  selected_failures="$verifier_failures"
  # Exactly one new failure per capability, and nothing else moved: the two
  # runs differ only in what the installation record says was selected.
  expected=$((unselected_failures + ${#capabilities[@]}))
  assert_eq "$expected" "$selected_failures" \
    "$platform failure count after selecting ${#capabilities[@]} capabilities with no state"
  printf 'PASS: %s fails by name once per selected capability with no state\n' "$platform"

  # Row 3: selected, with state this checkout cannot read.
  for_each_capability corrupt_state
  corrupt_state ai
  run_verifier
  for_each_capability assert_selected_corrupt
  assert_contains "$verifier_output" \
    "AI profile is recorded on this machine, but this checkout cannot read its profile state ($(state_path ai))"
  printf 'PASS: %s fails by name on state it cannot read, rather than skipping it\n' "$platform"

  # Row 1: selected, with the state a completed install writes. Every section
  # must reach its component verifier; what that verifier then decides about
  # this fixture machine is its own business and not this suite's.
  for_each_capability write_state
  write_state ai
  run_verifier
  for_each_capability assert_dispatched
  assert_contains "$verifier_output" 'AI profile verification'
  printf 'PASS: %s reaches the component verifier of a selected capability\n' "$platform"

  # Row 5: not selected, but state left behind. The deliberate behaviour is
  # that the checks still run -- what the state describes is on this machine --
  # and the disagreement between the two records is said out loud.
  record_selection base
  run_verifier
  for_each_capability assert_leftover
  assert_contains "$verifier_output" \
    "AI profile is not selected by this machine's recorded installation, but its profile state remains ($(state_path ai))"
  assert_contains "$verifier_output" 'AI profile verification'
  printf 'PASS: %s verifies an unselected leftover, and reports the disagreement\n' "$platform"

  for_each_capability remove_state
  remove_state ai
}

optional_capabilities=("${fedora_capabilities[@]}")
verifier_command="$repo_root/platforms/fedora/scripts/verify.sh"
verifier_summary='Fedora verification'
verifier_environment=()
exercise_matrix Fedora

# Fedora WSL, which the issue names for AI and containers specifically. Its
# verifier refuses to run outside WSL and off Fedora, so the fixture says which
# distribution it is and puts the two package commands it reaches for on PATH;
# everything the verifier then concludes about this machine is as wrong as it
# is for the Fedora case above, and just as irrelevant to what is asserted.
mkdir -p "$root/bin"
printf 'ID=fedora\n' >"$root/os-release"
for stub in dnf rpm; do
  printf '#!/bin/sh\nexit 1\n' >"$root/bin/$stub"
  chmod +x "$root/bin/$stub"
done

optional_capabilities=("${wsl_capabilities[@]}")
verifier_command="$repo_root/platforms/fedora-wsl/scripts/verify.sh"
verifier_summary='Fedora WSL verification'
verifier_environment=(
  "WSL_DISTRO_NAME=FedoraLinux"
  "OS_RELEASE_FILE=$root/os-release"
  "PATH=$root/bin:$PATH"
)
exercise_matrix 'Fedora WSL'

# --- Part 3: the same shape in every top-level verifier ----------------------
#
# The defect was one idiom repeated down a file, so the guard against its
# return is the idiom rather than any one site. A top-level verifier may not
# decide whether to run an optional capability's checks from one record alone:
# not from that capability's state file, which was the Fedora shape, and not
# from the installer flag, which was the macOS shape for containers and
# Tailscale. Both read as a verdict when they are only half the question.

# Which capabilities the rule is about, read from the registry rather than
# listed here, so it cannot be satisfied by a capability being forgotten. A
# flag gate is only a defect for a capability that records state of its own:
# macOS's --defaults applies system preferences, is no capability at all and
# records nothing, so a flag is the only thing it could ever be gated on.
mapfile -t stateful_capabilities < <(
  awk -F'\t' 'NR > 1 && $12 != "-" && $12 != "install" { print $1 }' \
    "$repo_root/config/capabilities.tsv" | sort -u
)
((${#stateful_capabilities[@]} > 0)) ||
  _test_die 'the capability registry named no capability with state, so this check proves nothing'

gate_lines() {
  local path="$1" line capability
  while IFS= read -r line; do
    case "$line" in
    'if [[ -f "$'*'_state" ]]; then')
      printf '%s\n' "$line"
      continue
      ;;
    esac
    for capability in "${stateful_capabilities[@]}"; do
      if [[ "$line" == "if [[ \"\$verify_${capability//-/_}\" == true ]]; then" ]]; then
        printf '%s\n' "$line"
        break
      fi
    done
  done <"$path"
}

top_level_verifiers=(
  "$repo_root/platforms/fedora/scripts/verify.sh"
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh"
  "$repo_root/platforms/macos/scripts/verify.sh"
)

for verifier in "${top_level_verifiers[@]}"; do
  # The guard: a file that does not dispatch through the shared helper at all
  # would pass the check below by having no optional sections to get wrong.
  assert_file_contains "$verifier" 'verify_optional_capability'
  found="$(gate_lines "$verifier")"
  assert_eq "" "$found" "$verifier still gates an optional section on one record alone"
done
printf 'PASS: no top-level verifier gates an optional section on one record alone\n'

# ... and the check can fail. The shape is absent from the tree by design, so
# it is planted in a scratch copy, where the reader must report it.
scratch_verifier="$root/planted-verify.sh"
{
  cat "$repo_root/platforms/fedora/scripts/verify.sh"
  printf '\n%s\n' 'if [[ -f "$planted_state" ]]; then'
  printf '%s\n' '  section "Planted state gate"'
  printf '%s\n' 'fi'
  printf '\n%s\n' 'if [[ "$verify_containers" == true ]]; then'
  printf '%s\n' '  section "Planted flag gate"'
  printf '%s\n' 'fi'
} >"$scratch_verifier"
planted="$(gate_lines "$scratch_verifier")"
assert_eq 'if [[ -f "$planted_state" ]]; then
if [[ "$verify_containers" == true ]]; then' "$planted" \
  'the reader did not report both planted single-record gates'
printf 'PASS: the reader reports a planted state-file gate and a planted flag gate\n'

printf '\nOptional-capability dispatch tests passed.\n'
