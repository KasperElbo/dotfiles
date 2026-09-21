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
# The one file that states the pin. Both scripts above read it, which is what
# stops the installer verifying one artifact and the verifier attesting to
# another; this suite reads it too rather than repeating any of its values.
dictation_lib="$repo_root/platforms/fedora/lib/dictation.sh"
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

# The pin this repository actually ships, read back out of the library the
# installer and the verifier both read, so the suite cannot drift from it and
# so a blanked pin fails here rather than silently reducing coverage.
shipped_sha256="$(sed -n 's/^DICTATION_HANDY_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' "$dictation_lib")"
[[ -n "$shipped_sha256" ]] ||
  _test_die 'the dictation library must ship a 64-character hexadecimal pinned digest'
shipped_version="$(sed -n 's/^DICTATION_HANDY_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$dictation_lib")"
[[ -n "$shipped_version" ]] ||
  _test_die 'the dictation library must pin an exact Handy version'

# The two readings above prove the file literally states its pin, which is the
# shape scripts/check-pin-freshness.sh reads. Sourcing it as well gives the
# suite the derived values -- the artifact name and the name-version-release.
# arch triple -- without restating upstream's naming convention a third time.
# shellcheck source=../platforms/fedora/lib/dictation.sh
source "$dictation_lib"
pinned_rpm="$(dictation_pinned_rpm)"
pinned_nvra="$(dictation_pinned_nvra)"
assert_eq "$shipped_version" "$(dictation_pinned_version)" \
  'the library states one version and derives another'
assert_eq "$shipped_sha256" "$(dictation_pinned_sha256)" \
  'the library states one digest and derives another'

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
# rpm is a read-only model of the package database, not a logged transaction:
# this profile only ever queries it, and the installer's fast path now has to
# ask it what is really installed rather than trusting its own state file. The
# suite drives it through RPM_PRESENT and RPM_HANDY_NVRA.
#
# The one query shape the shared library uses is answered and every other is
# rejected with the suite's strict-stub status, so a library that started
# asking rpm something else fails here rather than being quietly satisfied.
read -r -d '' rpm_stub <<'EOF' || true
#!/usr/bin/env bash
set -u
case "${1:-}" in
-q)
  for present in ${RPM_PRESENT:-}; do
    [[ "$2" == "$present" ]] && exit 0
  done
  exit 1
  ;;
-qf)
  shift
  if [[ "${1:-}" != --queryformat ]]; then
    printf 'rpm stub: -qf without the expected --queryformat: %s\n' "$*" >&2
    exit 96
  fi
  if [[ "$2" != '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' ]]; then
    printf 'rpm stub: unmodelled query format: %s\n' "$2" >&2
    exit 96
  fi
  [[ -n "${RPM_HANDY_NVRA:-}" ]] || exit 1
  printf '%s' "$RPM_HANDY_NVRA"
  ;;
-V)
  # A package rpm cannot verify at all answers with nothing and a failure,
  # which is a different thing from an intact package.
  if [[ "${RPM_VERIFY_UNREADABLE:-false}" == true ]]; then
    exit 1
  fi
  [[ -n "${RPM_VERIFY_OUTPUT:-}" ]] || exit 0
  printf '%s\n' "$RPM_VERIFY_OUTPUT"
  exit 1
  ;;
*)
  printf 'rpm stub rejected an unmodelled argv: %s\n' "$*" >&2
  exit 96
  ;;
esac
EOF
printf '%s\n' "$rpm_stub" >"$mock_bin/rpm"

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

# The modelled rpm database. RPM_PRESENT is the set of installed package
# names; RPM_HANDY_NVRA is the package that owns the handy binary, empty when
# nothing does. Both default to a healthy machine and a case overrides one for
# one run, the way RPM_PRESENT already did for the verifier.
rpm_state_environment() {
  printf '%s\n' \
    "RPM_PRESENT=${RPM_PRESENT-gtk-layer-shell wtype}" \
    "RPM_HANDY_NVRA=${RPM_HANDY_NVRA-}" \
    "RPM_VERIFY_OUTPUT=${RPM_VERIFY_OUTPUT-}" \
    "RPM_VERIFY_UNREADABLE=${RPM_VERIFY_UNREADABLE-false}"
}

read_rpm_state_environment() {
  local line
  rpm_env=()
  while IFS= read -r line; do rpm_env+=("$line"); done < <(rpm_state_environment)
}

# What a successful install leaves behind, as the machine would then see it:
# the binary on PATH, owned by the pinned rpm, with the profile's Wayland
# packages installed beside it. `handy` is absent before the first install.
install_handy_command() {
  ln -sf /usr/bin/true "$mock_bin/handy"
  RPM_HANDY_NVRA="$pinned_nvra"
  RPM_PRESENT="gtk-layer-shell wtype"
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
  local -a rpm_env=()
  shift
  read_rpm_state_environment
  run_capture "${base_environment[@]}" "${rpm_env[@]}" \
    "DOTFILES_TEST_HANDY_RPM=$fixture" "$installer" "$@"
}

# A run with no fixture at all, so the shipped pin and the shipped URL are
# what the installer uses.
run_installer_as_shipped() {
  local -a rpm_env=()
  read_rpm_state_environment
  run_capture "${base_environment[@]}" "${rpm_env[@]}" "$installer" "$@"
}

# A run where the bytes that arrive are not the bytes the pin describes. The
# later FIXTURE_RPM assignment wins, so the stubbed download serves the
# tampered file while the pin still names the fixture.
run_installer_serving() {
  local fixture="$1" served="$2"
  local -a rpm_env=()
  shift 2
  read_rpm_state_environment
  run_capture "${base_environment[@]}" "${rpm_env[@]}" \
    "DOTFILES_TEST_HANDY_RPM=$fixture" "FIXTURE_RPM=$served" "$installer" "$@"
}

reset_logs() {
  : >"$command_log"
  : >"$download_log"
}

reset_logs

# --- the shipped pin is a real, bumpable pin ------------------------------

grep -Eq '^DICTATION_HANDY_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$dictation_lib" ||
  _test_die 'the dictation library must pin an exact Handy version'
assert_eq "Handy-$shipped_version-1.x86_64.rpm" "$pinned_rpm" \
  'the pinned artifact name must be derived from the pinned version'

# The published file is Handy-<version>-1.x86_64.rpm and the package name
# inside it is `handy`, lower case; both were read out of the pinned artifact's
# own header. The identity rpm answers with therefore cannot be the file name
# with its suffix removed, and a simplification that made it so would match
# nothing on a real machine while every stub in this suite went on agreeing
# with it. That is what these two assertions exist to stop.
assert_eq "handy-$shipped_version-1.x86_64" "$pinned_nvra" \
  'the expected rpm identity must be the package name rpm records'
if [[ "${pinned_rpm%.rpm}" == "$pinned_nvra" ]]; then
  _test_die 'the artifact file name and the rpm identity must be pinned
separately: upstream publishes Handy-<version>-1.x86_64.rpm and rpm records
handy-<version>-1.x86_64, so deriving either from the other is wrong'
fi
grep -Fq '# network-source: handy-release' "$dictation_lib" ||
  _test_die 'the pinned download must name its registered network source'
grep -Fq '# network-source: handy-release' "$installer" ||
  _test_die 'the installer fetch must name its registered network source'
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

# --- a rerun repairs the machine rather than believing its own record -----
#
# The state file is this profile's record of what it once did, so on its own it
# says nothing about what is installed now. Each case below leaves the record
# exactly as a successful install wrote it and breaks the machine underneath
# it; the rerun has to notice and reinstall. Before this, each of them reported
# "already installed from the pinned artifact" and repaired nothing.

assert_repair_ran() {
  local what="$1"
  assert_success
  assert_not_contains "$TEST_OUTPUT" 'already installed from the pinned artifact'
  assert_file_contains "$command_log" 'sudo dnf install -y gtk-layer-shell wtype'
  assert_file_contains "$download_log" '.x86_64.rpm'
  if ! grep -Eq '^sudo dnf install -y /.*/Handy-[0-9.]+-1\.x86_64\.rpm$' "$command_log"; then
    _test_die "a rerun did not reinstall the pinned rpm after $what:\n$(cat "$command_log")"
  fi
  assert_file_line "$state_file" "sha256=$fixture_sha256"
}

reset_logs
RPM_HANDY_NVRA='' run_installer "$fixture_rpm"
assert_repair_ran 'the Handy rpm was removed'
printf 'PASS: a rerun reinstalls when the rpm is gone but the record survives\n'

reset_logs
RPM_HANDY_NVRA="unrelated-rpm-99.0-1.x86_64" run_installer "$fixture_rpm"
assert_repair_ran 'an unrelated package took ownership of handy'
printf 'PASS: a rerun reinstalls when handy belongs to some other package\n'

reset_logs
RPM_HANDY_NVRA="Handy-9.9.9-1.x86_64" run_installer "$fixture_rpm"
assert_repair_ran 'Handy was upgraded away from the pin'
printf 'PASS: a rerun reinstalls when the installed Handy is not the pinned release\n'

reset_logs
RPM_PRESENT="wtype" run_installer "$fixture_rpm"
assert_repair_ran 'a declared Wayland dependency was removed'
printf 'PASS: a rerun reinstalls when a declared dependency is missing\n'

# And with the machine healthy again it is still a no-op, so the cases above
# are drift being detected rather than the fast path having been disabled.
reset_logs
run_installer "$fixture_rpm"
assert_success
assert_contains "$TEST_OUTPUT" 'already installed from the pinned artifact'
assert_file_empty "$download_log"
assert_file_empty "$command_log"
printf 'PASS: the fast path still skips work on a machine that matches the pin\n'

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
for command_name in awk bash cat cut dirname env grep head sed sort tr sha256sum; do
  ln -sf "$(command -v "$command_name")" "$verify_bin/$command_name"
done

# The same model of the package database the installer ran against, so the two
# halves of the profile are held to one description of the machine. flatpak is
# deliberately absent, which is the no-duplicate-owner case.
printf '%s\n' "$rpm_stub" >"$verify_bin/rpm"
chmod +x "$verify_bin/rpm"

verify_sway_config="$test_root/xdg/sway/config"
mkdir -p "$(dirname "$verify_sway_config")"
cp "$sway_config" "$verify_sway_config"

# The verifier is given the same fixture the installer was, so the pin it
# checks against is the fixture's digest exactly as the installer's was. A
# verifier that did not honour the seam would be compared against the shipped
# digest while the state recorded the fixture's, and every case below would
# fail for that reason rather than for the one it is testing.
run_verifier() {
  local -a rpm_env=()
  read_rpm_state_environment
  run_capture env \
    "HOME=$test_root/home" \
    "XDG_CONFIG_HOME=$test_root/xdg" \
    "PATH=$verify_bin" \
    "${rpm_env[@]}" \
    "FLATPAK_HAS_HANDY=${FLATPAK_HAS_HANDY:-false}" \
    "DICTATION_SWAY_CONFIG=$verify_sway_config" \
    "DOTFILES_TEST_HANDY_RPM=${VERIFIER_FIXTURE-$fixture_rpm}" \
    "$verifier"
}

# One recorded value replaced for one run. Drift in the record is what several
# cases below are about, so each edits exactly one line and puts it back.
with_state_value() {
  local key="$1" value="$2"
  cp "$state_file" "$state_file.original"
  sed -i "s|^$key=.*|$key=$value|" "$state_file"
}

restore_state() {
  mv "$state_file.original" "$state_file"
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

RPM_HANDY_NVRA='' run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'owned by no rpm'
printf 'PASS: an unowned handy binary is reported as a second, unmanaged copy\n'

# --- the verifier establishes the pin rather than restating the record -----
#
# Each case below is one the verifier used to pass. The audit that found them
# supplied all of them at once -- a handy owned by an unrelated package, state
# recording version 0.0.0 and sixty-four zeroes as a digest -- and the verifier
# reported a digest-verified rpm and exited zero. They are separated here so a
# regression names which attestation stopped holding.

RPM_HANDY_NVRA="unrelated-rpm-99.0-1.x86_64" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "belongs to unrelated-rpm-99.0-1.x86_64, not the pinned $pinned_nvra"
assert_not_contains "$TEST_OUTPUT" 'handy is the pinned rpm'
printf 'PASS: a handy owned by some other package is not the pinned artifact\n'

# The same shape one release out. Nothing about the name is wrong here, only
# the version, which is the drift a machine actually sees when Handy is
# upgraded outside this profile.
RPM_HANDY_NVRA="Handy-9.9.9-1.x86_64" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "belongs to Handy-9.9.9-1.x86_64, not the pinned $pinned_nvra"
printf 'PASS: a differently versioned Handy rpm is not the pinned artifact\n'

# An installed package whose files no longer match what it shipped. The digest
# checked at download time says nothing about bytes replaced afterwards, so
# rpm's own per-file record is what answers this.
RPM_VERIFY_OUTPUT="S.5....T.  /usr/bin/handy" run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'no longer match what the package shipped'
assert_contains "$TEST_OUTPUT" '/usr/bin/handy'
printf 'PASS: an altered package is reported even though its download verified\n'

# A configuration file the operator edited is not tampering, and reporting it
# as such would train the operator to ignore this check.
RPM_VERIFY_OUTPUT="S.5....T.  c /etc/handy/handy.conf" run_verifier
assert_success
assert_contains "$TEST_OUTPUT" 'still matches what it shipped'
printf 'PASS: an edited configuration file is not reported as an altered package\n'

# rpm answering with nothing and a failure means it could not verify, which is
# not an intact package and must not be reported as one.
RPM_VERIFY_UNREADABLE=true run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'could not verify the files'
printf 'PASS: an unverifiable package is a failure, not a silent pass\n'

# Stale state: the machine is fine, the record is a release behind. Every one
# of these used to pass, because the record was only ever checked for shape.
with_state_value version 0.0.0
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "says Handy 0.0.0, but this repository pins $shipped_version"
assert_not_contains "$TEST_OUTPUT" 'the release this repository pins'
restore_state
printf 'PASS: a recorded version that is not the pinned one is stale, not evidence\n'

with_state_value sha256 0000000000000000000000000000000000000000000000000000000000000000
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'but this repository pins'
assert_not_contains "$TEST_OUTPUT" "the installed artifact's digest is the pinned one"
restore_state
printf 'PASS: a well-formed digest that is not the pinned one is rejected\n'

with_state_value sha256 not-a-digest
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'no usable SHA-256'
restore_state
printf 'PASS: a malformed recorded digest is still rejected\n'

with_state_value provider some-other-route
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "not 'pinned-release-rpm'"
restore_state
printf 'PASS: state written by some other route cannot pass as this profile\n'

with_state_value rpm Handy-0.0.0-1.x86_64.rpm
run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" "not the pinned $pinned_rpm"
restore_state
printf 'PASS: a recorded artifact name that is not the pinned one is rejected\n'

# The negative control for every comparison above: with no pin to compare
# against, the verifier must say so rather than passing the checks it can
# still reach. Without this the cases above would be indistinguishable from a
# verifier that had quietly stopped reading the pin at all.
VERIFIER_FIXTURE='' run_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'states no usable pinned SHA-256'
printf 'PASS: a verifier with no pin to check against fails rather than attests\n'

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
