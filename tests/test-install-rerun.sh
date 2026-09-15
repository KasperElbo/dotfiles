#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for ./install.sh --rerun: the remembered configuration is
# structured lifecycle state, it is reconstructed through the current parser,
# and only a completely successful install may replace it.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
export XDG_DATA_HOME="$test_root/data"
export XDG_STATE_HOME="$test_root/state"
export XDG_CACHE_HOME="$test_root/cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/dotfiles"

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/install-lifecycle.sh
source "$repo_root/common/lib/install-lifecycle.sh"

state="$(install_state_path)"

# The record a real parser run resolves for the given options. Using the
# installer itself keeps the fixtures honest: nothing here reimplements the
# option contract.
selection_of() {
  local platform="$1"
  shift
  "$repo_root/install.sh" --platform "$platform" --dry-run "$@" |
    sed -n 's/^Recorded rerun selection: //p'
}

record_success() {
  local platform="$1" capabilities="$2" selection="$3"
  install_lifecycle_begin "$platform" "$capabilities" \
    "./install.sh --platform $platform --non-interactive" "$selection"
  install_lifecycle_commit
}

remembered_selection() {
  profile_state_read "$state" last_successful_selection install
}

# --- 1. A successful install records its selection ---------------------------

selection_a="$(selection_of fedora --theme mocha --no-kde --no-latex --ai \
  --codex --no-firstmate --containers --containers-api-socket \
  --hardware ga402xz --secure-boot --charge-limit 80)"
[[ -n "$selection_a" ]] || _test_die 'the fedora installer printed no rerun selection'
record_success fedora base,dotnet-debug,containers,ai,codex "$selection_a"
assert_eq installed "$(profile_state_read "$state" status install)" 'lifecycle status'
assert_eq "$selection_a" "$(remembered_selection)" 'recorded selection A'
assert_eq fedora "$(profile_state_read "$state" last_successful_platform install)" \
  'recorded platform'
assert_eq 1 "$(profile_state_read "$state" selection_schema install)" 'selection schema'
printf 'PASS: a successful install records its resolved selection\n'

# --- 2. --rerun --dry-run resolves to A --------------------------------------

run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'Remembered configuration (last successful install)'
assert_contains "$TEST_OUTPUT" 'Platform:  fedora'
assert_contains "$TEST_OUTPUT" 'This run:  --dry-run'
assert_contains "$TEST_OUTPUT" 'No changes were made.'
# The reconstructed argument vector, parsed again, must resolve to the very
# same record: that is the round-trip the feature depends on.
assert_contains "$TEST_OUTPUT" "Recorded rerun selection: $selection_a"
printf 'PASS: --rerun --dry-run resolves to the remembered selection\n'

# --- 3. Rerunning the remembered configuration is idempotent -----------------

first_rerun="$TEST_OUTPUT"
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_eq "$first_rerun" "$TEST_OUTPUT" 'repeated --rerun --dry-run output'
state_before="$(sha256sum "$state")"
record_success fedora base,dotnet-debug,containers,ai,codex "$selection_a"
assert_eq "$state_before" "$(sha256sum "$state")" 'unchanged reapply rewrote state'
printf 'PASS: reapplying the remembered configuration is idempotent\n'

# --- 9-13. Round-trip fidelity of the reconstructed options ------------------

assert_contains "$first_rerun" '--theme mocha'
assert_contains "$first_rerun" '--charge-limit 80'
assert_contains "$first_rerun" '--hardware ga402xz'
assert_contains "$first_rerun" '--secure-boot'
assert_contains "$first_rerun" '--no-firstmate'
assert_contains "$first_rerun" '--codex'
assert_contains "$first_rerun" 'ASUS hardware:       ga402xz'
assert_contains "$first_rerun" 'Require Secure Boot: true'
assert_contains "$first_rerun" 'Battery limit:       80'
assert_contains "$first_rerun" 'AI Codex subcomponent: true'
assert_contains "$first_rerun" 'AI FirstMate subcomponent: false'
assert_contains "$first_rerun" 'AI GNHF subcomponent: inherit'
assert_contains "$first_rerun" 'common/install-ai.sh --codex --no-firstmate'
assert_not_contains "$first_rerun" '--gnhf'
assert_not_contains "$first_rerun" '--no-gnhf'
printf 'PASS: value-bearing, hardware and explicit negative choices round-trip\n'

# Transient execution controls are neither recorded nor replayed.
transient_selection="$(selection_of fedora --theme mocha --no-kde --no-latex \
  --ai --codex --no-firstmate --containers --containers-api-socket \
  --hardware ga402xz --secure-boot --charge-limit 80 \
  --dev-workflows --non-interactive)"
assert_eq "$selection_a" "$transient_selection" 'transient flags changed the record'
for transient in dry-run non-interactive dev-workflows help yes; do
  assert_not_contains "$selection_a" "$transient"
done
options_line="$(sed -n 's/^Options:   //p' <<<"$first_rerun")"
assert_not_contains "$options_line" '--non-interactive'
assert_not_contains "$options_line" '--dev-workflows'
assert_not_contains "$options_line" '--dry-run'
printf 'PASS: transient execution controls are not stored or replayed\n'

# --- 5-8. Only a complete success replaces the remembered configuration ------

selection_b="$(selection_of fedora --theme latte --no-kde --no-latex --ocaml)"
[[ "$selection_b" != "$selection_a" ]] || _test_die 'fixtures A and B are identical'

install_lifecycle_begin fedora base,dotnet-debug,ocaml \
  './install.sh --platform fedora --non-interactive' "$selection_b"
assert_eq "$selection_a" "$(remembered_selection)" 'applying state replaced the rerun target'
install_lifecycle_failed ocaml system 'ocaml,verify'
assert_eq failed "$(profile_state_read "$state" status install)" 'failed status'
assert_eq "$selection_a" "$(remembered_selection)" 'a failed install replaced the rerun target'
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_contains "$TEST_OUTPUT" "Recorded rerun selection: $selection_a"
printf 'PASS: a failed install leaves the previous successful selection intact\n'

install_lifecycle_begin fedora base,dotnet-debug,ocaml \
  './install.sh --platform fedora --non-interactive' "$selection_b"
install_lifecycle_failed verify 'system,terra,stow' none
assert_eq "$selection_a" "$(remembered_selection)" 'a failed verifier replaced the rerun target'
printf 'PASS: a failed verification leaves the previous successful selection intact\n'

record_success fedora base,dotnet-debug,containers,ai,codex "$selection_a"
state_before="$(sha256sum "$state")"
run_capture "$repo_root/install.sh" --dry-run --theme latte --no-kde --no-latex --ocaml
assert_success
assert_eq "$state_before" "$(sha256sum "$state")" 'a dry run wrote lifecycle state'
assert_eq "$selection_a" "$(remembered_selection)" 'a dry run replaced the rerun target'
printf 'PASS: a dry run neither writes lifecycle state nor replaces the target\n'

run_capture bash -c \
  "printf 'no\n' | '$repo_root/install.sh' --theme latte --no-kde --no-latex"
assert_success
assert_contains "$TEST_OUTPUT" 'Cancelled; no changes made.'
assert_eq "$state_before" "$(sha256sum "$state")" 'a cancelled install wrote lifecycle state'
assert_eq "$selection_a" "$(remembered_selection)" 'a cancelled install replaced the rerun target'
printf 'PASS: a cancelled install leaves the previous successful selection intact\n'

# --- 4/20. A successful B replaces A, and normal metadata still moves --------

record_success fedora base,dotnet-debug,ocaml "$selection_b"
assert_eq "$selection_b" "$(remembered_selection)" 'a successful install did not replace the target'
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_contains "$TEST_OUTPUT" "Recorded rerun selection: $selection_b"
assert_contains "$TEST_OUTPUT" 'OCaml profile:       true'
assert_eq base,dotnet-debug,ocaml \
  "$(profile_state_read "$state" requested_capabilities install)" 'requested capabilities'
assert_eq "$(install_repository_revision)" \
  "$(profile_state_read "$state" revision install)" 'recorded revision'
printf 'PASS: a successful install replaces the remembered configuration\n'

# Reapplying B records fresh lifecycle metadata without disturbing the record.
install_lifecycle_begin fedora base,dotnet-debug,ocaml \
  './install.sh --platform fedora --non-interactive' "$selection_b"
install_lifecycle_commit
assert_eq "$selection_b" "$(remembered_selection)" 'a successful rerun changed the record'
assert_eq installed "$(profile_state_read "$state" status install)" 'status after rerun'
printf 'PASS: a successful rerun updates metadata without changing the record\n'

# --- 18. Configuration-changing options are rejected alongside --rerun -------

for illegal in --theme --ai --hardware --no-kde --sway; do
  run_capture "$repo_root/install.sh" --rerun "$illegal"
  assert_failure
  assert_contains "$TEST_OUTPUT" "--rerun cannot be combined with $illegal"
  assert_contains "$TEST_OUTPUT" 'Allowed with --rerun'
done
run_capture "$repo_root/install.sh" --rerun --platform macos
assert_failure
assert_contains "$TEST_OUTPUT" 'remembered configuration is for platform fedora'
run_capture "$repo_root/install.sh" --rerun --dry-run --non-interactive
assert_success
printf 'PASS: only well-defined transient controls may accompany --rerun\n'

# --- 17. Unknown, removed and newly added options ----------------------------

removed_record="quantum-foam:true,$selection_b"
record_success fedora base,dotnet-debug,ocaml "$removed_record"
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_failure
assert_contains "$TEST_OUTPUT" 'Remembered option "quantum-foam" no longer exists'
printf 'PASS: a removed or renamed remembered option fails instead of being ignored\n'

added_record="${selection_b%,charge-limit:-}"
[[ "$added_record" != "$selection_b" ]] || _test_die 'fixture did not drop a trailing option'
record_success fedora base,dotnet-debug,ocaml "$added_record"
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'option --charge-limit was added after this configuration was recorded'
assert_contains "$TEST_OUTPUT" 'Battery limit:       unchanged'
printf 'PASS: an option added after the record is reported, not silently dropped\n'

# --- 14-16. Missing, incomplete, corrupt and unsupported state ---------------

record_success fedora base,dotnet-debug,ocaml "$selection_b"

install_lifecycle_begin fedora base,dotnet-debug,ocaml \
  './install.sh --platform fedora --non-interactive' "$selection_b"
mv "$state" "$test_root/applying.conf"

rm -f "$state"
run_capture "$repo_root/install.sh" --rerun
assert_failure
assert_contains "$TEST_OUTPUT" 'No installation has been recorded on this machine'
assert_contains "$TEST_OUTPUT" 'Run ./install.sh with the options you want once'
printf 'PASS: no previous installation gives a focused failure\n'

# Interrupted state that never carried a successful selection.
profile_state_write "$state" install applying platform=fedora \
  requested_capabilities=base observed_capabilities=pending \
  external_assurance=not-recorded repository=local-checkout \
  revision=deadbeef provenance=capability-manifest@deadbeef \
  started_at=2026-09-13T00:00:00Z 'rerun=./install.sh --non-interactive'
run_capture "$repo_root/install.sh" --rerun
assert_failure
assert_contains "$TEST_OUTPUT" 'No successful installation is recorded'
assert_contains "$TEST_OUTPUT" '"applying"'
printf 'PASS: interrupted-only state gives a focused failure\n'

# State written before --rerun existed: installed, but with no structured
# configuration. It must ask for one install rather than guess.
profile_state_write "$state" install installed platform=fedora \
  requested_capabilities=base,ocaml observed_capabilities=base,ocaml \
  external_assurance=not-recorded repository=local-checkout \
  revision=deadbeef provenance=capability-manifest@deadbeef \
  started_at=2026-09-13T00:00:00Z finished_at=2026-09-13T00:10:00Z \
  'rerun=./install.sh --platform fedora --ocaml --non-interactive'
run_capture "$repo_root/install.sh" --rerun
assert_failure
assert_contains "$TEST_OUTPUT" 'predates --rerun support'
assert_contains "$TEST_OUTPUT" 'for reference only (never executed)'
printf 'PASS: pre-#210 lifecycle state fails with a migration message\n'

printf 'schema_version=2\nprofile=install\nstatus=installed\nnot a state line\n' >"$state"
run_capture "$repo_root/install.sh" --rerun
assert_failure
assert_contains "$TEST_OUTPUT" 'corrupt or uses an unsupported schema'
printf 'PASS: corrupt lifecycle state fails\n'

record_success fedora base,dotnet-debug,ocaml "$selection_b"
sed -i 's/^selection_schema=1$/selection_schema=99/' "$state"
run_capture "$repo_root/install.sh" --rerun
assert_failure
assert_contains "$TEST_OUTPUT" 'selection schema "99"'
printf 'PASS: an unsupported selection schema fails\n'

# --- 19. No stored command text is ever executed -----------------------------

marker="$test_root/never-executed"
record_success fedora base,dotnet-debug,ocaml "$selection_b"
profile_state_write "$state" install installed platform=fedora \
  requested_capabilities=base,ocaml observed_capabilities=base,ocaml \
  external_assurance=not-recorded repository=local-checkout \
  "revision=$(install_repository_revision)" \
  "provenance=capability-manifest@$(install_repository_revision)" \
  started_at=2026-09-13T00:00:00Z finished_at=2026-09-13T00:10:00Z \
  "rerun=touch $marker" "selection=$selection_b" \
  "last_successful_selection=$selection_b" last_successful_platform=fedora \
  last_successful_at=2026-09-13T00:10:00Z selection_schema=1
run_capture "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_path_missing "$marker"
for implementation in install.sh scripts/install-main.sh \
  common/lib/install-selection.sh common/lib/install-lifecycle.sh; do
  if grep -nE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)|`' "$repo_root/$implementation"; then
    _test_die "$implementation can execute arbitrary command text"
  fi
done
printf 'PASS: remembered state is never executed as shell text\n'

# --- Platform fixtures -------------------------------------------------------

check_platform() {
  local platform="$1" capabilities="$2" expected="$3"
  shift 3
  local selection
  selection="$(selection_of "$platform" "$@")"
  [[ -n "$selection" ]] || _test_die "$platform printed no rerun selection"
  record_success "$platform" "$capabilities" "$selection"
  run_capture "$repo_root/install.sh" --rerun --dry-run
  assert_success
  assert_contains "$TEST_OUTPUT" "Platform:  $platform"
  assert_contains "$TEST_OUTPUT" "Recorded rerun selection: $selection"
  assert_contains "$TEST_OUTPUT" "$expected"
  printf 'PASS: %s selections round-trip through --rerun\n' "$platform"
}

check_platform fedora-wsl base,dotnet-debug,ocaml,containers \
  'Containers API socket: true' \
  --theme frappe --ocaml --containers --containers-api-socket
check_platform macos base,dotnet-debug,tailscale \
  'Tailscale profile:  true' \
  --theme latte --no-defaults --tailscale
# The configuration the Apple Silicon job replays. Its AI subcomponents are
# tristates, so this proves they survive the whole path -- installer, record,
# --rerun, parser -- and not only the selection library in isolation.
check_platform macos base,dotnet-debug,ocaml,ai,codex,firstmate,gnhf,backpass \
  'AI GNHF subcomponent:      true' \
  --theme mocha --ocaml --no-containers --no-tailscale --defaults \
  --ai --codex --firstmate --gnhf --backpass
check_platform parrot-ctf base,vm-guest 'Theme:                  mocha' --theme mocha

# --- Manifest coupling -------------------------------------------------------

while IFS=$'\t' read -r platform option _kind on_flag _off _default _values capability _summary; do
  [[ "$platform" != platform ]] || continue
  [[ "$capability" != - ]] || continue
  manifest_flag="$(awk -F '\t' -v p="$platform" -v c="$capability" \
    'NR>1 && $1==c && $2==p && $15=="implemented" {print $4; exit}' \
    "$repo_root/config/capabilities.tsv")"
  assert_eq "$on_flag" "$manifest_flag" \
    "capability manifest flag for $option ($capability) on $platform"
done <"$repo_root/config/install-options.tsv"
printf 'PASS: persistent options agree with the capability manifest\n'

# --- The hint a failed install shows ----------------------------------------
#
# Only a completely successful install becomes the remembered configuration, so
# a failed one has nothing for --rerun to reapply and must print a literal
# command instead. That command is rendered from the same selection, because a
# fixed './install.sh --platform <p> --non-interactive' would tell the user to
# install the platform defaults rather than the machine they asked for.

# Every platform renders it the same way. A hard-coded
# './install.sh --platform <p> --non-interactive' used to send Fedora WSL and
# Parrot users back to the platform defaults (#225, DOC-036).
for platform in fedora fedora-wsl macos parrot-ctf; do
  installer="$repo_root/platforms/$platform/install.sh"
  grep -Fq "DOTFILES_RERUN_COMMAND=\"\$(install_lifecycle_rerun_command $platform \"\$install_selection\")\"" \
    "$installer" ||
    _test_die "$platform does not render its failure hint from the resolved selection"
  if grep -Eq "DOTFILES_RERUN_COMMAND='|build_rerun_command" "$installer"; then
    _test_die "$platform still hard-codes or hand-rolls its failure hint"
  fi
done
printf 'PASS: every platform renders the failed-run hint from the shared selection\n'

failed_selection="$(selection_of macos --theme mocha --ocaml --no-containers \
  --no-tailscale --defaults --ai --codex --no-gnhf)"
failed_command="$(install_lifecycle_rerun_command macos "$failed_selection")"
assert_contains "$failed_command" './install.sh --platform macos'
assert_contains "$failed_command" '--theme mocha'
assert_contains "$failed_command" '--ocaml'
assert_contains "$failed_command" '--ai'
assert_contains "$failed_command" '--codex'
assert_contains "$failed_command" '--no-gnhf'
assert_contains "$failed_command" '--non-interactive'
# An omitted AI sub-flag is an additive request, so it must stay absent here
# too: naming it would turn it into an install or a removal on the next run.
assert_not_contains "$failed_command" '--firstmate'
assert_not_contains "$failed_command" '--backpass'

# A record this checkout can no longer interpret must not produce a command
# that silently means something else.
degraded_command="$(install_lifecycle_rerun_command macos 'theme:mocha,removed-option:true')"
assert_eq './install.sh --platform macos --non-interactive' "$degraded_command" \
  'rerun command for an uninterpretable selection'
printf 'PASS: a failed install is told the command that reproduces its selection\n'

printf 'Installer --rerun lifecycle, round-trip and refusal tests passed.\n'
