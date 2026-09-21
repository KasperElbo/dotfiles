#!/usr/bin/env bash
set -euo pipefail

# The optional macOS dictation profile: its manifest registration, the pinned
# artifact it installs, and the installer's behaviour against a mocked Apple
# Silicon machine.
#
# Everything here runs on Linux as well as macOS. No case reaches the network
# or a real /Applications: `curl`, `hdiutil`, `ditto` and `defaults` are
# fixtures, the applications directory is a temporary one selected through
# MACOS_APPLICATIONS_DIR, and the "downloaded" disk image is a local file whose
# digest the fixture controls. The verifier's own dictation section is proven
# against the full mocked machine in tests/test-macos-verification.sh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git sha256sum

installer="$repo_root/platforms/macos/scripts/install-dictation.sh"
pin_library="$repo_root/platforms/macos/lib/dictation.sh"

# The checkout as this suite found it. Every install below runs against a
# staged copy under a temporary root, so this must be byte-identical
# afterwards: a profile whose installer wrote into the repository could commit
# recorded audio, a downloaded model or a token by accident, which the
# dictation issue forbids outright.
CHECKOUT_BEFORE="$(git -C "$repo_root" status --porcelain --untracked-files=all)"

# --- The pin, read from the library rather than restated here ----------------

read_pin() {
  local name="$1"
  sed -n "s/^$name=\"\\(.*\\)\"\$/\\1/p" "$pin_library" | head -n 1
}

pinned_version="$(read_pin DICTATION_GHOST_PEPPER_VERSION)"
pinned_sha256="$(read_pin DICTATION_GHOST_PEPPER_SHA256)"
pinned_team="$(read_pin DICTATION_GHOST_PEPPER_TEAM_ID)"
pinned_app="$(read_pin DICTATION_GHOST_PEPPER_APP)"

[[ -n "$pinned_version" && -n "$pinned_sha256" && -n "$pinned_team" && -n "$pinned_app" ]] ||
  _test_die "could not read the Ghost Pepper pin from $pin_library"
[[ "$pinned_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  _test_die "the pinned SHA-256 is not a 64-character hex digest: $pinned_sha256"

# --- Manifest registration ---------------------------------------------------
#
# The capability, the installer option and the provenance row have to agree
# with each other and with the script. The generic schema checks live in the
# repository validators; what is proven here is that this profile is actually
# in all three, disabled by default, and pinned at the strongest tier.

capability_row="$(awk -F'\t' '$1 == "dictation" && $2 == "macos"' \
  "$repo_root/config/capabilities.tsv")"
[[ -n "$capability_row" ]] ||
  _test_die 'config/capabilities.tsv has no macos row for the dictation capability'
IFS=$'\t' read -r _ _ _ capability_flag capability_default capability_dependencies \
  _ capability_provider _ _ capability_verifier capability_state \
  capability_state_profile capability_docs \
  _ capability_status capability_installers capability_ci_scope <<<"$capability_row"
assert_eq '--dictation' "$capability_flag" 'dictation capability flag'
assert_eq 'disabled' "$capability_default" 'dictation capability default'
assert_eq 'base' "$capability_dependencies" 'dictation capability dependencies'
assert_eq 'upstream-dmg' "$capability_provider" 'dictation capability provider'
assert_eq 'implemented' "$capability_status" 'dictation capability status'
assert_eq 'platforms/macos/scripts/verify.sh' "$capability_verifier" 'dictation verifier'
assert_eq 'macos-dictation' "$capability_state" 'dictation state file name'
# The file is named for the platform and the schema inside it is not: macOS
# and Fedora both record a `dictation` profile, in their own state files, and
# scripts/doctor.sh compares the file against this column rather than against
# the file's own `profile=` key.
assert_eq 'dictation' "$capability_state_profile" 'dictation state schema'
assert_eq 'docs/profiles/dictation.md#macos' "$capability_docs" 'dictation documentation'
assert_eq 'platforms/macos/scripts/install-dictation.sh' "$capability_installers" \
  'dictation installer'
# No CI job can grant a microphone or a desktop session, so this profile is
# deliberately never selected by the real-install workflow. That has to be a
# recorded decision with its reason, not an omission: see the manual checklist
# in docs/profiles/dictation.md.
case "$capability_ci_scope" in
excluded:*) ;;
*) _test_die "the macos dictation row must record its CI exclusion, got: $capability_ci_scope" ;;
esac
assert_contains "$capability_ci_scope" 'docs/profiles/dictation.md'

# The only platform row this change owns. The Fedora and Windows rows for the
# same capability belong to their own changes, and this suite must not start
# passing or failing because of them.
assert_eq 'macos' \
  "$(awk -F'\t' '$1 == "dictation" { printf "%s ", $2 }' \
    "$repo_root/config/capabilities.tsv" | sed 's/ $//' | tr ' ' '\n' |
    grep -Fx macos)" \
  'the macos dictation capability row is present'

option_row="$(awk -F'\t' '$1 == "macos" && $2 == "dictation"' \
  "$repo_root/config/install-options.tsv")"
[[ -n "$option_row" ]] ||
  _test_die 'config/install-options.tsv has no macos dictation option'
IFS=$'\t' read -r _ _ option_kind option_on option_off option_default _ \
  option_capability _ <<<"$option_row"
assert_eq 'boolean' "$option_kind" 'dictation option kind'
assert_eq '--dictation' "$option_on" 'dictation option on flag'
assert_eq '--no-dictation' "$option_off" 'dictation option off flag'
assert_eq 'false' "$option_default" 'dictation option default'
assert_eq 'dictation' "$option_capability" 'dictation option capability'

source_row="$(awk -F'\t' '$1 == "ghost-pepper-release"' \
  "$repo_root/config/network-sources.tsv")"
[[ -n "$source_row" ]] ||
  _test_die 'config/network-sources.tsv has no ghost-pepper-release row'
IFS=$'\t' read -r _ _ _ _ source_url _ source_tier _ _ source_integrity \
  source_cadence source_rollback source_consumers <<<"$source_row"
assert_eq 'immutable-verified' "$source_tier" 'ghost-pepper-release tier'
assert_eq 'sha256-pinned' "$source_integrity" 'ghost-pepper-release integrity'
assert_eq 'manual-bump' "$source_cadence" 'ghost-pepper-release cadence'
assert_contains "$source_rollback" 'platforms/macos/lib/dictation.sh'
assert_contains "$source_consumers" 'platforms/macos/scripts/install-dictation.sh'
# The registry URL is a template over the pinned tag; the script must build the
# same URL from the same tag, so a bumped pin cannot leave the two disagreeing.
assert_eq "${source_url//\$\{ghost_pepper_version\}/$pinned_version}" \
  "https://github.com/matthartman/ghost-pepper/releases/download/v$pinned_version/GhostPepper.dmg" \
  'ghost-pepper-release URL resolves to the pinned release asset'
printf 'PASS: the capability, installer option and provenance row agree\n'

# --- Nothing here weakens Gatekeeper, SIP or macOS privacy consent -----------
#
# The reason this profile is allowed to install a downloaded application at all
# is that the application is notarized and Gatekeeper accepts it as it ships.
# A future edit that "fixes" a Gatekeeper refusal by disabling the check, or by
# stripping the quarantine or the signature, would silently trade that away.

dictation_sources=(
  "$installer"
  "$pin_library"
  "$repo_root/platforms/macos/scripts/verify.sh"
)
forbidden_pattern='csrutil[[:space:]]+disable|spctl[[:space:]]+--master-disable|spctl[[:space:]]+--global-disable|xattr[[:space:]]+.*quarantine|--remove-signature|codesign[[:space:]]+(-s|--sign)[[:space:]]'
if grep -E -n "$forbidden_pattern" "${dictation_sources[@]}"; then
  _test_die 'a dictation profile script weakens Gatekeeper, SIP or code signing'
fi
# Nor may it embed a credential for a transcription or model service: this
# profile is local-only and configures no account.
credential_pattern='api[_-]?key[[:space:]]*=|HUGGING_?FACE_?(HUB_)?(API_)?TOKEN|OPENAI_API_KEY|Bearer '
if grep -E -n "$credential_pattern" "${dictation_sources[@]}"; then
  _test_die 'a dictation profile script embeds a credential or provider token'
fi
printf 'PASS: no script disables Gatekeeper/SIP or embeds a credential\n'

# --- The installer plan ------------------------------------------------------

default_plan="$("$repo_root/install.sh" --platform macos --dry-run)"
assert_contains "$default_plan" 'Dictation profile:  false'
assert_contains "$default_plan" 'dictation:false'
assert_not_contains "$default_plan" 'Install the optional dictation profile'
assert_not_contains "$default_plan" 'install-dictation.sh'
printf 'PASS: a default macOS install neither plans nor selects dictation\n'

selected_plan="$("$repo_root/install.sh" --platform macos --dry-run --dictation)"
assert_contains "$selected_plan" 'Dictation profile:  true'
assert_contains "$selected_plan" 'dictation:true'
assert_contains "$selected_plan" \
  '[dictation] Install the optional dictation profile (pinned Ghost Pepper disk image).'
assert_contains "$selected_plan" 'Microphone and Accessibility approval remain interactive.'
assert_contains "$selected_plan" 'No changes were made.'
printf 'PASS: --dictation appears in the dry-run plan and the rerun selection\n'

# The flag is remembered as an ordinary persistent option, so --no-dictation
# after a --dictation install records the removal rather than being ignored.
off_plan="$("$repo_root/install.sh" --platform macos --dry-run --dictation --no-dictation)"
assert_contains "$off_plan" 'Dictation profile:  false'
assert_not_contains "$off_plan" 'Install the optional dictation profile'
printf 'PASS: --no-dictation turns the selection back off\n'

assert_file_contains "$repo_root/platforms/macos/bootstrap-help.txt" '--dictation/--no-dictation'
printf 'PASS: the platform help advertises the flag\n'

# --- A mocked Apple Silicon machine ------------------------------------------

new_test_root() {
  test_new_root
  local root="$TEST_ROOT"
  local bin="$root/bin"

  mkdir -p "$root/applications" "$root/config/dotfiles" "$root/payload"
  : >"$root/commands.log"

  # The disk image the fixture "downloads". Its bytes are arbitrary; what
  # matters is that the test controls its digest, so both the matching and the
  # mismatching case are real digest comparisons rather than skipped ones.
  printf 'ghost-pepper fixture disk image\n' >"$root/payload/GhostPepper.dmg"

  cat >"$bin/curl" <<'EOF_CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$COMMAND_LOG"
output=""
previous=""
for argument in "$@"; do
  [[ "$previous" != --output ]] || output="$argument"
  previous="$argument"
done
[[ -n "$output" ]] || exit 2
[[ "${MOCK_CURL_EXIT:-0}" == 0 ]] || exit "$MOCK_CURL_EXIT"
cat "$MOCK_DMG_PAYLOAD" >"$output"
EOF_CURL

  cat >"$bin/hdiutil" <<'EOF_HDIUTIL'
#!/usr/bin/env bash
printf 'hdiutil %s\n' "$*" >>"$COMMAND_LOG"
case "${1:-}" in
attach)
  [[ "${MOCK_HDIUTIL_ATTACH_EXIT:-0}" == 0 ]] || exit "$MOCK_HDIUTIL_ATTACH_EXIT"
  mount_point=""
  previous=""
  for argument in "$@"; do
    [[ "$previous" != -mountpoint ]] || mount_point="$argument"
    previous="$argument"
  done
  [[ -n "$mount_point" ]] || exit 2
  bundle="$mount_point/${MOCK_DMG_APP_NAME:-GhostPepper.app}"
  mkdir -p "$bundle/Contents/MacOS"
  printf 'version=%s\n' "${MOCK_DMG_VERSION:-0.0.0}" >"$bundle/Contents/Info.plist"
  printf 'mach-o fixture\n' >"$bundle/Contents/MacOS/GhostPepper"
  printf '%s\n' "$mount_point" >"$MOUNTED_MARKER"
  ;;
detach)
  rm -f -- "$MOUNTED_MARKER"
  ;;
esac
exit 0
EOF_HDIUTIL

  cat >"$bin/ditto" <<'EOF_DITTO'
#!/usr/bin/env bash
printf 'ditto %s\n' "$*" >>"$COMMAND_LOG"
[[ "${MOCK_DITTO_EXIT:-0}" == 0 ]] || exit "$MOCK_DITTO_EXIT"
source_path="$1"
destination="$2"
mkdir -p "$destination"
cp -R "$source_path/." "$destination/"
EOF_DITTO

  # `defaults read <bundle>/Contents/Info CFBundleShortVersionString`, answered
  # from the one-line fixture plist the hdiutil stub writes.
  cat >"$bin/defaults" <<'EOF_DEFAULTS'
#!/usr/bin/env bash
printf 'defaults %s\n' "$*" >>"$COMMAND_LOG"
[[ "${1:-}" == read && "${3:-}" == CFBundleShortVersionString ]] || exit 1
plist="$2.plist"
[[ -f "$plist" ]] || exit 1
value="$(sed -n 's/^version=//p' "$plist" | head -n 1)"
[[ -n "$value" ]] || exit 1
printf '%s\n' "$value"
EOF_DEFAULTS

  chmod +x "$bin/curl" "$bin/hdiutil" "$bin/ditto" "$bin/defaults"
  printf '%s\n' "$root"
}

fixture_environment() {
  local root="$1"
  printf '%s\n' \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "XDG_DATA_HOME=$root/data" \
    "XDG_STATE_HOME=$root/state" \
    "XDG_CACHE_HOME=$root/cache" \
    "TMPDIR=$root/tmp" \
    "PATH=$root/bin:$PATH" \
    "COMMAND_LOG=$root/commands.log" \
    "MOUNTED_MARKER=$root/mounted" \
    "MOCK_DMG_PAYLOAD=$root/payload/GhostPepper.dmg" \
    "MOCK_DMG_VERSION=$pinned_version" \
    "MACOS_APPLICATIONS_DIR=$root/applications" \
    "DOTFILES_TEST_UNAME_S=Darwin" \
    "DOTFILES_TEST_UNAME_M=arm64" \
    "DOTFILES_TEST_MACOS=true"
}

# The fixture payload's real digest, written into the pin the installer reads.
# The installer is run against a copy of the repository whose pin library names
# this digest, so the digest comparison is genuine in both directions without
# ever downloading the real 27 MB release.
stage_repository() {
  local root="$1" digest
  local checkout="$root/checkout"

  mkdir -p "$checkout/platforms/macos/scripts" "$checkout/platforms/macos/lib" \
    "$checkout/common/lib" "$root/tmp"
  cp -R "$repo_root/common/lib/." "$checkout/common/lib/"
  cp "$repo_root/platforms/macos/lib/macos.sh" "$checkout/platforms/macos/lib/"
  cp "$pin_library" "$checkout/platforms/macos/lib/dictation.sh"
  cp "$installer" "$checkout/platforms/macos/scripts/"

  digest="$(sha256sum "$MOCK_PAYLOAD_PATH" | cut -d' ' -f1)"
  # Not `sed -i`: that spelling is a GNU extension, and these suites also run
  # on macOS, whose sed reads the next argument as a backup suffix.
  local pin="$checkout/platforms/macos/lib/dictation.sh"
  sed "s/^DICTATION_GHOST_PEPPER_SHA256=.*/DICTATION_GHOST_PEPPER_SHA256=\"$digest\"/" \
    "$pin" >"$pin.rewritten"
  mv -- "$pin.rewritten" "$pin"
  printf '%s\n' "$checkout/platforms/macos/scripts/install-dictation.sh"
}

# run_installer <root> [VAR=value ...] [-- installer-argument ...]
run_installer() {
  local root="$1"
  shift
  local item separator=false
  local environment=() overrides=() arguments=()
  for item in "$@"; do
    if [[ "$item" == -- ]]; then
      separator=true
      continue
    fi
    if [[ "$separator" == true ]]; then
      arguments+=("$item")
    else
      overrides+=("$item")
    fi
  done
  mapfile -t environment < <(fixture_environment "$root")
  run_capture env "${environment[@]}" "${overrides[@]}" \
    "$STAGED_INSTALLER" "${arguments[@]}"
}

# --- The standalone dry run mutates nothing ----------------------------------

root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"

run_installer "$root" -- --dry-run
assert_success
assert_contains "$TEST_OUTPUT" "Ghost Pepper $pinned_version"
assert_contains "$TEST_OUTPUT" "releases/download/v$pinned_version/GhostPepper.dmg"
assert_contains "$TEST_OUTPUT" 'Currently installed: none'
assert_contains "$TEST_OUTPUT" 'No changes were made.'
assert_file_empty "$root/commands.log"
assert_path_missing "$root/applications/$pinned_app"
assert_path_missing "$root/config/dotfiles/macos-dictation.conf"
printf 'PASS: the standalone dry run downloads, mounts and installs nothing\n'

# --- A fresh install -----------------------------------------------------

run_installer "$root"
assert_success
assert_file_contains "$root/commands.log" 'hdiutil attach'
assert_file_contains "$root/commands.log" 'hdiutil detach'
assert_file_contains "$root/commands.log" 'ditto'
assert_path_missing "$root/mounted"
assert_path_exists "$root/applications/$pinned_app/Contents/MacOS/GhostPepper"

# The download went through the repository's bounded, HTTPS-only fetch helper
# at the pinned URL, not to some other host or over plain HTTP.
assert_file_contains "$root/commands.log" \
  "https://github.com/matthartman/ghost-pepper/releases/download/v$pinned_version/GhostPepper.dmg"
assert_file_contains "$root/commands.log" '--proto =https'

state_file="$root/config/dotfiles/macos-dictation.conf"
assert_file_line "$state_file" 'profile=dictation'
assert_file_line "$state_file" 'status=installed'
assert_file_line "$state_file" 'application=ghost-pepper'
assert_file_line "$state_file" 'provider=upstream-dmg'
assert_file_line "$state_file" "version=$pinned_version"
assert_file_line "$state_file" "team_id=$pinned_team"

# The epilogue is the whole interactive-permission contract: a user who never
# reads it never grants Accessibility, and dictation silently does nothing.
assert_contains "$TEST_OUTPUT" 'Microphone'
assert_contains "$TEST_OUTPUT" 'Accessibility'
assert_contains "$TEST_OUTPUT" 'leave Gatekeeper enabled'
assert_contains "$TEST_OUTPUT" 'No account, API key or cloud provider is'
printf 'PASS: a fresh install downloads, verifies, mounts, copies and detaches\n'

# --- Rerunning is a no-op ----------------------------------------------------

first_state="$(sha256sum "$state_file")"
: >"$root/commands.log"

run_installer "$root"
assert_success
assert_contains "$TEST_OUTPUT" "already installed"
assert_file_not_contains "$root/commands.log" 'curl'
assert_file_not_contains "$root/commands.log" 'hdiutil'
assert_file_not_contains "$root/commands.log" 'ditto'
assert_eq "$first_state" "$(sha256sum "$state_file")" \
  'the dictation state file changed on a no-op rerun'
printf 'PASS: rerunning at the pinned version downloads nothing and rewrites nothing\n'

# --- A digest mismatch installs nothing --------------------------------------

root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"
# Staging recorded the digest of the payload as it was; changing the payload
# afterwards is exactly the "these are not the reviewed bytes" case.
printf 'a different disk image\n' >"$root/payload/GhostPepper.dmg"

run_installer "$root"
assert_failure
assert_contains "$TEST_OUTPUT" 'SHA-256 mismatch'
assert_file_not_contains "$root/commands.log" 'hdiutil attach'
assert_path_missing "$root/applications/$pinned_app"
assert_path_missing "$root/config/dotfiles/macos-dictation.conf"
printf 'PASS: a digest mismatch stops before mounting and installs nothing\n'

# --- A failed copy still detaches and leaves nothing behind ------------------

root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"

run_installer "$root" MOCK_DITTO_EXIT=1
assert_failure
assert_file_contains "$root/commands.log" 'hdiutil attach'
assert_file_contains "$root/commands.log" 'hdiutil detach'
assert_path_missing "$root/mounted"
assert_path_missing "$root/applications/$pinned_app"
# No staging directory is left in the applications directory either.
remaining="$(find "$root/applications" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')"
assert_eq 0 "$remaining" 'a failed install left something in the applications directory'
assert_path_missing "$root/config/dotfiles/macos-dictation.conf"
printf 'PASS: a failed copy detaches the image and writes no state\n'

# --- A disk image without the expected bundle is refused ---------------------

root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"

run_installer "$root" MOCK_DMG_APP_NAME=SomethingElse.app
assert_failure
assert_contains "$TEST_OUTPUT" "does not contain $pinned_app"
assert_file_contains "$root/commands.log" 'hdiutil detach'
assert_path_missing "$root/applications/$pinned_app"
printf 'PASS: a disk image without the expected bundle is refused and detached\n'

# --- An install replaces a build that is not the pinned one ------------------

root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"
mkdir -p "$root/applications/$pinned_app/Contents/MacOS"
printf 'version=0.0.1\n' >"$root/applications/$pinned_app/Contents/Info.plist"
printf 'stale\n' >"$root/applications/$pinned_app/Contents/MacOS/GhostPepper"

run_installer "$root"
assert_success
assert_file_contains "$root/commands.log" 'hdiutil attach'
assert_file_contains "$root/applications/$pinned_app/Contents/Info.plist" \
  "version=$pinned_version"
assert_file_not_contains "$root/applications/$pinned_app/Contents/MacOS/GhostPepper" stale
printf 'PASS: a build other than the pinned one is replaced\n'

# --- Privacy: the installer writes nothing into the checkout -----------------
#
# The issue is explicit that recorded audio, transcription history, models,
# API keys and application state must never be committable. The installer's own
# outputs are the part of that this repository controls, so this asserts where
# they land rather than trusting a .gitignore to catch them later.

checkout_after="$(git -C "$repo_root" status --porcelain --untracked-files=all)"
assert_eq "$CHECKOUT_BEFORE" "$checkout_after" \
  'the dictation installer changed the checkout'
assert_path_missing "$repo_root/GhostPepper.app"
printf 'PASS: nothing the installer creates lands inside the repository\n'

# The one file it writes under the user's configuration holds the pin, not
# anything the user said, and no credential.
root="$(new_test_root)"
MOCK_PAYLOAD_PATH="$root/payload/GhostPepper.dmg"
STAGED_INSTALLER="$(stage_repository "$root")"
run_installer "$root"
assert_success
state_file="$root/config/dotfiles/macos-dictation.conf"
while IFS= read -r line; do
  case "${line%%=*}" in
  schema_version | profile | status | application | provider | version | \
    artifact | sha256 | bundle_id | team_id | path) ;;
  *) _test_die "unexpected key in the dictation state file: $line" ;;
  esac
done <"$state_file"
# Nothing else appeared under the user's configuration directory.
written="$(cd "$root/config" && find . -type f | sort)"
assert_eq './dotfiles/macos-dictation.conf' "$written" \
  'the dictation installer wrote an unexpected file under XDG_CONFIG_HOME'
printf 'PASS: the only state written is the pin record, with no transcript or credential\n'

printf '\nmacOS dictation profile manifest, install, idempotency and privacy tests passed.\n'
