#!/usr/bin/env bash
set -euo pipefail

# macOS AI profile contract.
#
# The macOS platform must consume the shared AI installer and verifier rather
# than fork its own. These tests assert that the selection a user typed reaches
# that shared code unchanged, that an unselected profile mutates nothing, and
# that one unsupported component costs exactly one sub-flag.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
test_install_cleanup_trap

installer="$repo_root/install.sh"
macos_root="$repo_root/platforms/macos"
manifest="$repo_root/config/capabilities.tsv"

dry_run() {
  run_capture "$installer" --platform macos --dry-run "$@"
  assert_success
}

# ---------------------------------------------------------------------------
# Option surface
# ---------------------------------------------------------------------------

run_capture "$installer" --platform macos --help
assert_success
for option in --ai --no-ai --codex --firstmate --gnhf --backpass; do
  assert_contains "$TEST_OUTPUT" "$option"
done
printf 'PASS: macOS help advertises the AI profile and its subcomponents\n'

# The help, the manifest and the parser must advertise the same set. A flag in
# the manifest that the parser does not accept is a capability documented but
# unreachable; the reverse is one installable but undeclared.
while IFS=$'\t' read -r capability platform _ cli_flag _ _ _ _ _ _ _ _ _ _ _ status _; do
  [[ "$platform" == macos ]] || continue
  case "$capability" in ai | codex | firstmate | gnhf | backpass) ;; *) continue ;; esac
  [[ "$status" == implemented ]] || continue
  grep -Fq -- "$cli_flag" "$macos_root/bootstrap-help.txt" ||
    _test_die "macOS help does not advertise the implemented $cli_flag"
  grep -Fq -- "  $cli_flag)" "$macos_root/install.sh" ||
    _test_die "macOS parser does not accept the implemented $cli_flag"
done <"$manifest"
printf 'PASS: manifest, help and parser advertise the same AI options\n'

# ---------------------------------------------------------------------------
# Selection reaches the shared installer
# ---------------------------------------------------------------------------

dry_run
assert_contains "$TEST_OUTPUT" 'AI tooling profile: false'
assert_not_contains "$TEST_OUTPUT" 'common/install-ai.sh'
assert_not_contains "$TEST_OUTPUT" '[ai]'
printf 'PASS: an unselected AI profile plans no AI mutation at all\n'

dry_run --ai
assert_contains "$TEST_OUTPUT" 'AI tooling profile: true'
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh'
# Omitting every sub-flag must pass no sub-flag at all: the shared installer
# reads that as "keep whatever is installed", which an explicit --no-<component>
# would silently turn into a removal.
assert_not_contains "$TEST_OUTPUT" 'install-ai.sh --no-'
assert_contains "$TEST_OUTPUT" 'AI Codex subcomponent:     inherit'
printf 'PASS: --ai alone reaches the shared installer with additive defaults\n'

dry_run --ai --codex --firstmate --gnhf --backpass
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh --codex --firstmate --gnhf --backpass'
assert_contains "$TEST_OUTPUT" 'AI Codex subcomponent:     true'
assert_contains "$TEST_OUTPUT" 'AI FirstMate subcomponent: true'
assert_contains "$TEST_OUTPUT" 'AI GNHF subcomponent:      true'
assert_contains "$TEST_OUTPUT" 'AI backpass subcomponent:  true'
printf 'PASS: every selected subcomponent reaches the shared installer\n'

# Additive semantics: an omitted sub-flag must stay distinguishable from an
# explicit removal, all the way into the argument vector.
dry_run --ai --codex --no-firstmate
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh --codex --no-firstmate'
assert_contains "$TEST_OUTPUT" 'AI FirstMate subcomponent: false'
assert_contains "$TEST_OUTPUT" 'AI GNHF subcomponent:      inherit'
printf 'PASS: omitted and explicitly removed subcomponents stay distinguishable\n'

# The AI step must run after mise: the shared installer resolves every tool
# through mise, so installing before it would have nothing to resolve against.
dry_run --ai
mise_step="$(printf '%s\n' "$TEST_OUTPUT" | grep -n '\[mise\]' | cut -d: -f1)"
ai_step="$(printf '%s\n' "$TEST_OUTPUT" | grep -n '\[ai\]' | cut -d: -f1)"
[[ -n "$mise_step" && -n "$ai_step" ]] || _test_die 'the dry run did not plan both mise and ai'
((ai_step > mise_step)) ||
  _test_die 'the AI profile is installed before the mise environment exists'
printf 'PASS: the AI profile installs after the mise environment is active\n'

# ---------------------------------------------------------------------------
# Rejections
# ---------------------------------------------------------------------------

for option in --codex --firstmate --gnhf --backpass; do
  run_capture "$installer" --platform macos --dry-run "$option"
  assert_failure
  assert_contains "$TEST_OUTPUT" "requires --ai"
done
printf 'PASS: a subcomponent flag without --ai is rejected\n'

# One unsupported component must cost exactly one sub-flag, never the profile.
test_new_root
demoted="$TEST_ROOT/capabilities.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" }
  $1 == "gnhf" && $2 == "macos" { $8 = "unsupported"; $16 = "unsupported" }
  { print }' "$manifest" >"$demoted"

run_capture env "CAPABILITY_MANIFEST=$demoted" \
  "$installer" --platform macos --dry-run --ai --gnhf
assert_failure
assert_contains "$TEST_OUTPUT" "--gnhf is not supported on Apple Silicon macOS"
assert_contains "$TEST_OUTPUT" "rerun without --gnhf"
printf 'PASS: an unsupported component rejects its own sub-flag with a reason\n'

run_capture env "CAPABILITY_MANIFEST=$demoted" \
  "$installer" --platform macos --dry-run --ai --codex --firstmate
assert_success
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh --codex --firstmate'
printf 'PASS: one unsupported component does not disable the AI profile\n'

# Removing an unsupported component must stay possible, or a demotion would
# strand whatever is already installed.
run_capture env "CAPABILITY_MANIFEST=$demoted" \
  "$installer" --platform macos --dry-run --ai --no-gnhf
assert_success
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh --no-gnhf'
printf 'PASS: an unsupported component can still be removed\n'

# ---------------------------------------------------------------------------
# No macOS-specific fork
# ---------------------------------------------------------------------------

if grep -Eq 'npm (install|i) .*-g|brew install .*(claude|codex|herdr)' \
  "$macos_root/install.sh" "$macos_root/scripts/"*.sh "$macos_root/Brewfile"; then
  _test_die 'macOS installs an AI tool through Homebrew or a global npm prefix'
fi
for package in claude claude-code codex herdr gnhf backpass treehouse; do
  if grep -Eq "^brew \"$package\"$|^cask \"$package\"$" "$macos_root/Brewfile"; then
    _test_die "Brewfile duplicates the mise-owned AI tool: $package"
  fi
done
printf 'PASS: macOS adds no Homebrew or global npm duplicate of an AI tool\n'

grep -Fq 'common/install-ai.sh' "$macos_root/install.sh" ||
  _test_die 'the macOS installer does not call the shared AI installer'
grep -Fq 'common/verify-ai.sh' "$macos_root/scripts/verify.sh" ||
  _test_die 'the macOS verifier does not call the shared AI verifier'
for forked in install-ai verify-ai; do
  if [[ -e "$macos_root/scripts/$forked.sh" ]]; then
    _test_die "a macOS-specific AI implementation exists: scripts/$forked.sh"
  fi
done
printf 'PASS: macOS reuses the shared AI installer and verifier\n'

# The macOS verifier owns the one question the shared verifier cannot answer.
macos_verifier="$macos_root/scripts/verify.sh"
grep -Fq 'would need Rosetta' "$macos_verifier" ||
  _test_die 'the macOS verifier does not reject an Intel-only AI binary'
printf 'PASS: macOS verification adds the arm64 check\n'

# The global npm prefix used to be ruled out here and nowhere else, which left
# the same duplicate undetected on Fedora. It belongs to the shared verifier
# now, so assert it there -- and assert it is gone from here, or the two could
# drift back apart without anything noticing.
grep -Fq 'check_no_global_npm_duplicate' "$repo_root/common/verify-ai.sh" ||
  _test_die 'the shared AI verifier does not rule out a global npm duplicate'
! grep -Fq 'npm ls --global' "$macos_verifier" ||
  _test_die 'the macOS verifier still inspects the global npm prefix itself'
printf 'PASS: the global npm prefix is ruled out once, for every platform\n'

# ---------------------------------------------------------------------------
# Rerun and lifecycle
# ---------------------------------------------------------------------------

grep -Fq 'macos_selected_capabilities' "$macos_root/install.sh" ||
  _test_die 'the macOS lifecycle record does not use the resolved selection'

# The AI selection must serialize through the shared persistent-selection
# model, not a macOS-local rerun store. Every AI option is declared for macos
# in the option manifest, recorded by the installer, and round-trips back to
# the same argument vector.
options_manifest="$repo_root/config/install-options.tsv"
for option in ai codex firstmate gnhf backpass; do
  awk -F '\t' -v o="$option" \
    '$1 == "macos" && $2 == o { found = 1 } END { exit !found }' "$options_manifest" ||
    _test_die "the option manifest does not declare macos/$option as persistent"
  grep -Fq "install_selection_set $option " "$macos_root/install.sh" ||
    _test_die "the macOS installer does not record $option in the persistent selection"
done
# Tristates, so an omitted sub-flag round-trips as "inherit" rather than being
# hardened into an install or a removal.
for option in codex firstmate gnhf backpass; do
  kind="$(awk -F '\t' -v o="$option" \
    '$1 == "macos" && $2 == o { print $3; exit }' "$options_manifest")"
  [[ "$kind" == tristate ]] ||
    _test_die "macos/$option is declared $kind; an omitted AI sub-flag must stay distinguishable"
done
if grep -Fq 'build_rerun_command' "$macos_root/install.sh"; then
  _test_die 'macOS still builds its own rerun command instead of using the shared selection model'
fi
printf 'PASS: the AI selection serializes through the shared persistent-selection model\n'

# A failed install has no remembered configuration to reapply, so the command
# it prints must reproduce the selection of the run that failed -- including
# its AI subcomponents -- rather than this platform's defaults.
# shellcheck disable=SC2016 # Matching the literal assignment in install.sh.
grep -Fq 'DOTFILES_RERUN_COMMAND="$(install_lifecycle_rerun_command macos "$install_selection")"' \
  "$macos_root/install.sh" ||
  _test_die 'the macOS failure hint is not rendered from the resolved selection'
printf 'PASS: a failed macOS install names the command that reproduces its selection\n'

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/install-selection.sh
source "$repo_root/common/lib/install-selection.sh"

record='theme:mocha,ocaml:true,containers:false,tailscale:false,defaults:true,ai:true,codex:true,firstmate:inherit,gnhf:false,backpass:inherit'
rendered="$(install_selection_render_display macos "$record")" ||
  _test_die 'a macOS selection carrying AI options did not round-trip'
assert_contains "$rendered" '--ai'
assert_contains "$rendered" '--codex'
assert_contains "$rendered" '--no-gnhf'
assert_contains "$rendered" '--ocaml'
assert_contains "$rendered" '--theme mocha'
# inherit must render nothing at all: it is the additive request.
assert_not_contains "$rendered" '--firstmate'
assert_not_contains "$rendered" '--backpass'
# shellcheck disable=SC2086 # The rendered argument vector is intentionally split.
run_capture "$installer" --platform macos --dry-run $rendered
assert_success
assert_contains "$TEST_OUTPUT" 'common/install-ai.sh --codex --no-gnhf'
printf 'PASS: a remembered macOS selection replays into the same AI request\n'

# Stale history must not outlive the implementation it was waiting for.
if grep -rn 'issue #16' "$macos_root" "$repo_root/docs/platforms/macos.md" >/dev/null 2>&1; then
  _test_die 'macOS still claims the AI profile is waiting for issue #16'
fi
printf 'PASS: the stale "waiting for issue #16" claim is gone\n'

printf 'macOS AI profile contract tests passed.\n'
