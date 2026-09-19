#!/usr/bin/env bash
set -euo pipefail

# Fedora dictation profile: the pinned Handy artifact, the Wayland
# dependencies, the Sway-owned toggle, and the verifier.
#
# Nothing here needs Handy, dnf, Sway, a Wayland session, an audio device or
# the network. The rpm is a fixture file whose digest the suite computes, the
# download is a stub, and every privileged or packaging command is an
# allow-list that rejects an argv the profile is not supposed to run.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

installer="$repo_root/platforms/fedora/scripts/install-dictation.sh"
verifier="$repo_root/platforms/fedora/scripts/verify-dictation.sh"
sway_config="$repo_root/platforms/fedora/stow/sway/.config/sway/config"

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
download_log="$test_root/downloads.log"
mkdir -p "$test_root/xdg" "$test_root/home"

# The artifact the stubbed download produces, and its real digest. Using the
# host's sha256sum rather than stubbing it keeps the verification under test
# genuine: a mismatch case below has to fail through the same code path a
# tampered download would.
fixture_rpm="$test_root/fixture-handy.x86_64.rpm"
printf 'not really an rpm, but a deterministic one\n' >"$fixture_rpm"
fixture_sha256="$(sha256sum "$fixture_rpm" | cut -d' ' -f1)"

# What a tampered download looks like: the pin still describes the artifact
# above, but these are the bytes that arrive. Verification has to reject them.
tampered_rpm="$test_root/tampered-handy.x86_64.rpm"
printf 'not really an rpm, and not the pinned one either\n' >"$tampered_rpm"

# The digest this repository actually ships, read back out of the installer so
# the suite cannot drift from it and so a blanked pin fails here rather than
# silently reducing coverage.
shipped_sha256="$(sed -n 's/^handy_rpm_sha256="\([0-9a-f]\{64\}\)"$/\1/p' "$installer")"
[[ -n "$shipped_sha256" ]] ||
  _test_die 'the installer must ship a 64-character hexadecimal pinned digest'

# dnf is an allow-list, not an unconditional success: an unexpected package
# transaction has to fail the suite. The staged rpm path is a mktemp directory
# that is not known until the run, so the two accepted shapes are matched
# rather than listed literally.
cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
"install -y gtk-layer-shell wtype") exit 0 ;;
"install -y /"*"/Handy-"*"-1.x86_64.rpm") exit 0 ;;
*)
  printf 'dictation fixture rejected unsupported dnf argv: %s\n' "$*" >&2
  exit 96
  ;;
esac
EOF
cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF
cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
printf 'rpm %s\n' "$*" >>"$COMMAND_LOG"
EOF

# fetch_to_file's curl invocation, reduced to the two things that matter here:
# where the bytes go, and that the URL was the pinned one.
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
destination=""
url=""
while (($#)); do
  case "$1" in
  --output) destination="$2"; shift 2 ;;
  --) shift; url="$1"; shift ;;
  *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$DOWNLOAD_LOG"
[[ -n "$destination" ]] || exit 2
cat "$FIXTURE_RPM" >"$destination"
EOF

printf 'ID=fedora\n' >"$test_root/os-release"
chmod +x "$mock_bin"/*

# `handy` stands in for the installed application: absent before the first
# install, present afterwards, exactly as rpm ownership would make it.
install_handy_command() {
  ln -sf /usr/bin/true "$mock_bin/handy"
}

base_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/xdg"
  "XDG_DATA_HOME=$test_root/data"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "DOWNLOAD_LOG=$download_log"
  "FIXTURE_RPM=$fixture_rpm"
  "OS_RELEASE_FILE=$test_root/os-release"
)

state_file="$test_root/xdg/dotfiles/dictation.conf"

# A run against a fixture artifact: the installer fetches that file and
# verifies it against its own digest. Passing an empty fixture leaves the pin
# unrecorded, which is how the fail-closed guard is exercised.
run_installer() {
  local fixture="$1"
  shift
  run_capture "${base_environment[@]}" "DOTFILES_TEST_HANDY_RPM=$fixture" \
    "$installer" "$@"
}

# A run with no fixture at all, so the shipped pin and the shipped URL are
# what the installer uses.
run_installer_as_shipped() {
  run_capture "${base_environment[@]}" "$installer" "$@"
}

# A run where the bytes that arrive are not the bytes the pin describes. The
# later FIXTURE_RPM assignment wins, so the stubbed download serves the
# tampered file while the pin still names the fixture.
run_installer_serving() {
  local fixture="$1" served="$2"
  shift 2
  run_capture "${base_environment[@]}" "DOTFILES_TEST_HANDY_RPM=$fixture" \
    "FIXTURE_RPM=$served" "$installer" "$@"
}

reset_logs() {
  : >"$command_log"
  : >"$download_log"
}

reset_logs

# --- the shipped pin is a real, bumpable pin ------------------------------

grep -Eq '^handy_version="[0-9]+\.[0-9]+\.[0-9]+"$' "$installer" ||
  _test_die 'the installer must pin an exact Handy version'
grep -Fq 'handy_rpm="Handy-${handy_version}-1.x86_64.rpm"' "$installer" ||
  _test_die 'the pinned artifact name must be derived from the pinned version'
grep -Fq '# network-source: handy-release' "$installer" ||
  _test_die 'the pinned download must name its registered network source'
printf 'PASS: the Handy release is pinned by version and artifact name\n'

# --- dry-run changes nothing and states the provider ----------------------

run_installer_as_shipped --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'Provider:           pinned upstream release rpm, verified by SHA-256'
assert_contains "$TEST_OUTPUT" "Pinned SHA-256:     $shipped_sha256"
assert_contains "$TEST_OUTPUT" 'https://github.com/cjpais/Handy/releases/download/'
assert_contains "$TEST_OUTPUT" 'Fedora packages:    gtk-layer-shell wtype'
assert_contains "$TEST_OUTPUT" 'Super+O, owned by Sway (pkill -USR2 -x handy)'
assert_contains "$TEST_OUTPUT" 'No changes were made.'
assert_file_empty "$command_log"
assert_file_empty "$download_log"
assert_path_missing "$state_file"
printf 'PASS: --dry-run describes the pinned provider and mutates nothing\n'

# A dry run is also how an operator discovers the pin is missing, so it has to
# say so rather than printing a plausible-looking plan.
run_installer "" --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'not recorded'
assert_file_empty "$command_log"
printf 'PASS: --dry-run reports an unrecorded pin instead of a plausible plan\n'

# --- an unpinned artifact stops before anything happens -------------------

run_installer ""
assert_failure
assert_contains "$TEST_OUTPUT" 'No SHA-256 is pinned'
assert_contains "$TEST_OUTPUT" 'Bumping the pinned Handy release'
assert_file_empty "$command_log"
assert_file_empty "$download_log"
assert_path_missing "$state_file"
printf 'PASS: an unpinned artifact fails closed before any download or sudo\n'

# --- the pinned artifact is downloaded, verified and installed ------------

install_handy_command
run_installer "$fixture_rpm"
assert_success
assert_file_contains "$command_log" 'sudo dnf install -y gtk-layer-shell wtype'
assert_file_contains "$download_log" 'https://dotfiles-test.invalid/'
assert_file_contains "$download_log" '.x86_64.rpm'
if ! grep -Eq '^sudo dnf install -y /.*/Handy-[0-9.]+-1\.x86_64\.rpm$' "$command_log"; then
  _test_die "the verified rpm was not installed:\n$(cat "$command_log")"
fi
printf 'PASS: the pinned rpm is downloaded, verified and installed\n'

# Installing an artifact dnf cannot check a signature on must never be bought
# by telling dnf to stop checking signatures. The digest is what stands in for
# the missing signature, so no invocation may carry a flag or a --setopt that
# relaxes the check.
if grep -Eq -- '--nogpgcheck|gpgcheck=0|gpgcheck=False' "$command_log"; then
  _test_die 'the dictation installer relaxed dnf signature checking'
fi
printf 'PASS: no dnf signature check is relaxed to install the pinned rpm\n'

# --- no /dev/uinput, no input group, no dotool ----------------------------

for forbidden in usermod gpasswd dotool uinput; do
  assert_file_not_contains "$command_log" "$forbidden"
done
if grep -Eq '(^|[^a-z-])usermod([^a-z-]|$)' "$installer"; then
  _test_die 'the dictation installer must never add the user to a group'
fi
assert_file_contains "$state_file" 'paste_backend=wtype'
printf 'PASS: text insertion goes through wtype; no group change, no uinput\n'

# --- the recorded state names the exact artifact --------------------------

assert_file_contains "$state_file" 'profile=dictation'
assert_file_contains "$state_file" 'provider=pinned-release-rpm'
assert_file_line "$state_file" "sha256=$fixture_sha256"
assert_file_contains "$state_file" 'status=installed'
printf 'PASS: the profile state records the verified artifact\n'

# --- rerunning is idempotent and re-downloads nothing ---------------------

first_state="$(sha256sum "$state_file")"
reset_logs
run_installer "$fixture_rpm"
assert_success
assert_contains "$TEST_OUTPUT" 'already installed from the pinned artifact'
assert_file_empty "$download_log"
assert_file_empty "$command_log"
assert_eq "$first_state" "$(sha256sum "$state_file")" \
  'a rerun rewrote the dictation state'
printf 'PASS: a rerun with the pinned artifact already installed is a no-op\n'

# --- a changed pin reinstalls rather than trusting the old state ----------

reset_logs
run_installer_serving "$tampered_rpm" "$fixture_rpm"
assert_failure
assert_contains "$TEST_OUTPUT" 'SHA-256 mismatch'
assert_file_contains "$download_log" '.x86_64.rpm'
assert_file_not_contains "$command_log" 'Handy-'
assert_file_line "$state_file" "sha256=$fixture_sha256"
printf 'PASS: a digest mismatch aborts before the rpm is installed\n'

# --- nothing the installer creates can be committed -----------------------

# The state file is the only thing the installer writes outside Handy's own
# directory, and it lives under XDG_CONFIG_HOME, not in the checkout.
[[ "$state_file" == "$test_root/"* ]] ||
  _test_die 'the dictation state must live outside the repository'
assert_path_missing "$repo_root/.config/com.pais.handy"
assert_path_missing "$repo_root/$(basename "$fixture_rpm")"
assert_path_missing "$repo_root/dictation.conf"

tracked="$(git -C "$repo_root" ls-files)"
while IFS= read -r tracked_path; do
  case "$tracked_path" in
  *com.pais.handy* | *.wav | *.ogg | *.opus | *.ggml | *.gguf | *transcription*)
    _test_die "a dictation runtime artifact is tracked: $tracked_path"
    ;;
  esac
done <<<"$tracked"
printf 'PASS: no recorded audio, history, model or application state is tracked\n'

run_capture python3 "$repo_root/scripts/validate-repository-hygiene.py"
assert_success
printf 'PASS: repository hygiene agrees\n'

# --- the Sway session owns the dictation key ------------------------------

assert_file_line "$sway_config" 'bindsym $mod+o exec pkill -USR2 -x handy'
sway_mod_o="$(grep -c '^bindsym \$mod+o ' "$sway_config")"
assert_eq 1 "$sway_mod_o" 'Super+O is bound more than once in the Sway config'
assert_file_contains "$repo_root/config/actions.tsv" 'sway.dictation.toggle'
# The signal, not SIGUSR1: upstream removed the SIGUSR1 handler on Linux
# because WebKitGTK uses it internally, and a binding that still sent it would
# crash Handy rather than dictate.
assert_file_not_contains "$sway_config" 'pkill -USR1'
printf 'PASS: Sway owns Super+O and signals the running Handy with SIGUSR2\n'

# --- the verifier reports through the shared verification contract --------

# The verifier gets only the commands this profile owns, so a dictation tool
# installed on the machine running the suite can never stand in for one the
# profile failed to install.
verify_bin="$test_root/verify-bin"
mkdir -p "$verify_bin"
for command_name in handy wtype; do
  ln -sf /usr/bin/true "$verify_bin/$command_name"
done
for command_name in awk bash cat cut dirname env grep head sed sort tr; do
  ln -sf "$(command -v "$command_name")" "$verify_bin/$command_name"
done

# rpm answers for the two declared packages and owns the handy binary; flatpak
# is deliberately absent, which is the no-duplicate-owner case.
cat >"$verify_bin/rpm" <<EOF
#!/usr/bin/env bash
case "\$1" in
-q)
  for present in \$RPM_PRESENT; do
    [[ "\$2" == "\$present" ]] && exit 0
  done
  exit 1
  ;;
-qf)
  [[ "\${RPM_OWNS_HANDY:-true}" == true ]] || exit 1
  printf 'Handy-0.0.0-1.x86_64\n'
  ;;
esac
EOF
chmod +x "$verify_bin/rpm"

verify_sway_config="$test_root/xdg/sway/config"
mkdir -p "$(dirname "$verify_sway_config")"
cp "$sway_config" "$verify_sway_config"

run_verifier() {
  run_capture env \
    "HOME=$test_root/home" \
    "XDG_CONFIG_HOME=$test_root/xdg" \
    "PATH=$verify_bin" \
    "RPM_PRESENT=${RPM_PRESENT:-gtk-layer-shell wtype}" \
    "RPM_OWNS_HANDY=${RPM_OWNS_HANDY:-true}" \
    "FLATPAK_HAS_HANDY=${FLATPAK_HAS_HANDY:-false}" \
    "DICTATION_SWAY_CONFIG=$verify_sway_config" \
    "$verifier"
}

run_verifier
assert_success
assert_contains "$TEST_OUTPUT" 'Dictation verification passed.'
assert_contains "$TEST_OUTPUT" 'wtype (no /dev/uinput'
assert_contains "$TEST_OUTPUT" 'Sway binds the dictation toggle'
assert_contains "$TEST_OUTPUT" 'no duplicate Flatpak ownership is possible'
printf 'PASS: the verifier passes on a correctly installed profile\n'

# With flatpak present, the question is answered rather than skipped, and a
# second Handy installed through it is the duplicate ownership this profile
# refuses to leave unreported.
cat >"$verify_bin/flatpak" <<'EOF'
#!/usr/bin/env bash
[[ "${FLATPAK_HAS_HANDY:-false}" == true ]]
EOF
chmod +x "$verify_bin/flatpak"

run_verifier
assert_success
assert_contains "$TEST_OUTPUT" 'no duplicate Flatpak installation of Handy'

FLATPAK_HAS_HANDY=true run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'also installed as a Flatpak'
rm -f "$verify_bin/flatpak"
printf 'PASS: a Flatpak installed beside the pinned rpm is reported as a duplicate owner\n'

rm -f "$verify_bin/handy"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'handy not found'
assert_contains "$TEST_OUTPUT" 'Dictation verification failed:'
ln -sf /usr/bin/true "$verify_bin/handy"
printf 'PASS: the verifier fails when the application is missing\n'

rm -f "$verify_bin/wtype"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'wtype not found'
ln -sf /usr/bin/true "$verify_bin/wtype"
printf 'PASS: a missing wtype is a failure, not a note\n'

RPM_PRESENT="wtype" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'gtk-layer-shell is not installed'
printf 'PASS: the verifier reads its packages from the capability manifest\n'

RPM_OWNS_HANDY=false run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'owned by no rpm'
printf 'PASS: an unowned handy binary is reported as a second, unmanaged copy\n'

mv "$verify_sway_config" "$verify_sway_config.hidden"
run_verifier
assert_success
assert_contains "$TEST_OUTPUT" 'NOT OBSERVED'
assert_contains "$TEST_OUTPUT" 'unobserved check(s)'
mv "$verify_sway_config.hidden" "$verify_sway_config"
printf 'PASS: an absent Sway session is unobserved rather than a false failure\n'

sed -i 's/pkill -USR2 -x handy/true/' "$verify_sway_config"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'no dictation binding'
printf 'PASS: a Sway session without the binding fails verification\n'

# --- an unselected profile verifies clean by being absent -----------------

rm -f "$state_file"
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'No dictation profile state'
printf 'PASS: the standalone verifier says so when the profile was never installed\n'

if ! grep -Fq 'dotfiles/dictation.conf' "$repo_root/platforms/fedora/scripts/verify.sh"; then
  _test_die 'the platform verifier must run the dictation verifier only when the profile state exists'
fi
printf 'PASS: the platform verifier runs the dictation verifier on state, not on presence\n'

printf 'Dictation pinned-artifact, ownership, privacy and verification tests passed.\n'
