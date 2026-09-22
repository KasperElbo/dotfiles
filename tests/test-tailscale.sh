#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path jq sha256sum timeout

new_test_root() {
  local test_root
  test_root="$(mktemp -d)"

  local mock_bin="$test_root/bin"
  mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" \
    "$test_root/etc/yum.repos.d" "$test_root/handlers"
  : >"$test_root/commands.log"
  : >"$test_root/enabled-units"
  : >"$test_root/active-units"

  test_stub_init "$test_root"
  for command_name in dnf sudo systemctl; do
    test_stub_install "$test_root" "$command_name"
  done
  test_stub_allow "$test_root" dnf install -y dnf5-plugins
  test_stub_allow "$test_root" dnf config-manager addrepo --overwrite \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
  test_stub_allow "$test_root" dnf install -y tailscale
  test_stub_allow "$test_root" dnf --dump-repo-config=tailscale
  test_stub_allow "$test_root" sudo dnf install -y dnf5-plugins
  test_stub_allow "$test_root" sudo dnf config-manager addrepo --overwrite \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
  test_stub_allow "$test_root" sudo dnf install -y tailscale
  test_stub_allow "$test_root" sudo systemctl enable --now tailscaled
  test_stub_allow "$test_root" systemctl enable --now tailscaled
  test_stub_allow "$test_root" systemctl is-enabled --quiet tailscaled
  test_stub_allow "$test_root" systemctl is-active --quiet tailscaled

  # The verifier asks DNF what it will enforce for the tailscale
  # repository, so the fixture has to be a machine DNF knows it on.
  # MOCK_TAILSCALE_GPGCHECK is what the fetched .repo file turned out to
  # say: whatever that is becomes the machine's policy verbatim.
  cat >"$test_root/handlers/dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --dump-repo-config=tailscale ]]; then
  [[ -e "$TAILSCALE_REPO_FILE" ]] || exit 1
  printf '======== "tailscale" repository configuration: ========\n'
  printf 'gpgcheck = %s\npkg_gpgcheck = %s\n' \
    "${MOCK_TAILSCALE_GPGCHECK:-1}" "${MOCK_TAILSCALE_GPGCHECK:-1}"
  exit 0
fi

printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"

if [[ "${1:-}" == config-manager && "${2:-}" == addrepo ]]; then
  : >"$TAILSCALE_REPO_FILE"
fi
exit 0
EOF

  cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -q && "${2:-}" == dnf5-plugins ]]; then
  [[ "${MOCK_DNF5_PLUGINS_INSTALLED:-false}" == true ]]
  exit $?
fi
exit 0
EOF

  cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF

  cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"

cmd="${1:-}"
shift || true

case "$cmd" in
enable)
  for arg in "$@"; do
    case "$arg" in --*) continue ;; esac
    grep -qx "$arg" "$ENABLED_UNITS" 2>/dev/null ||
      printf '%s\n' "$arg" >>"$ENABLED_UNITS"
    if [[ "$*" == *--now* ]]; then
      grep -qx "$arg" "$ACTIVE_UNITS" 2>/dev/null ||
        printf '%s\n' "$arg" >>"$ACTIVE_UNITS"
    fi
  done
  ;;
is-enabled)
  grep -qx "${*: -1}" "$ENABLED_UNITS" 2>/dev/null
  exit $?
  ;;
is-active)
  grep -qx "${*: -1}" "$ACTIVE_UNITS" 2>/dev/null
  exit $?
  ;;
esac
exit 0
EOF

  cat >"$mock_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >>"$COMMAND_LOG"

case "${1:-}" in
version)
  exit "${MOCK_TAILSCALE_VERSION_EXIT:-0}"
  ;;
status)
  [[ "${MOCK_TAILSCALE_STATUS_EXIT:-0}" == 0 ]] || exit "${MOCK_TAILSCALE_STATUS_EXIT}"
  if [[ -n "${MOCK_TAILSCALE_STATUS_RAW:-}" ]]; then
    printf '%s\n' "$MOCK_TAILSCALE_STATUS_RAW"
  else
    printf '{"BackendState":"%s"}\n' "${MOCK_TAILSCALE_BACKEND_STATE:-NeedsLogin}"
  fi
  ;;
esac
EOF

  chmod +x "$mock_bin"/* "$test_root/handlers"/*

  printf 'ID=fedora\n' >"$test_root/os-release"

  printf '%s\n' "$test_root"
}

make_parserless_path() {
  local test_root="$1"
  local sandbox="$test_root/no-jq"
  local name resolved

  mkdir -p "$sandbox"
  for name in env bash cat cut dirname grep head id mktemp sed sort stat tr \
    uname wc; do
    resolved="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue
    ln -sf "$resolved" "$sandbox/$name"
  done
  printf '%s\n' "$test_root/bin:$sandbox"
}

base_environment() {
  local test_root="$1"

  printf '%s\n' \
    "HOME=$test_root/home" \
    "XDG_CONFIG_HOME=$test_root/xdg" \
    "XDG_DATA_HOME=$test_root/home/.local/share" \
    "PATH=$test_root/bin:$PATH" \
    "TEST_STUB_ROOT=$test_root" \
    "COMMAND_LOG=$test_root/commands.log" \
    "OS_RELEASE_FILE=$test_root/os-release" \
    "TAILSCALE_REPO_FILE=$test_root/etc/yum.repos.d/tailscale.repo" \
    "ENABLED_UNITS=$test_root/enabled-units" \
    "ACTIVE_UNITS=$test_root/active-units"
}

fail_with_context() {
  local message="$1"
  local file="${2:-}"
  printf '%s\n' "$message" >&2
  if [[ -n "$file" ]]; then
    printf -- '--- %s ---\n' "$file" >&2
    cat "$file" >&2 2>/dev/null || printf '(missing or unreadable)\n' >&2
  fi
  exit 1
}

# --- dry-run makes no changes -----------------------------------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-tailscale.sh" --dry-run)"

grep -Fq 'add from https://pkgs.tailscale.com/stable/fedora/tailscale.repo' \
  <<<"$dry_run_output"
grep -Fq "not automated; 'tailscale up' is never run here" <<<"$dry_run_output"
grep -Fq 'none (no auth key, no OAuth secret, no tailnet policy)' \
  <<<"$dry_run_output"
grep -Fq 'No changes were made.' <<<"$dry_run_output"

if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Dry-run executed a mutating command.' \
    "$test_root/commands.log"
fi
if [[ -e "$test_root/etc/yum.repos.d/tailscale.repo" ]]; then
  fail_with_context 'Dry-run created the Tailscale repository file.'
fi

rm -rf -- "$test_root"
printf 'PASS: dry-run reports the plan without mutating anything\n'

# --- fresh install adds the repo, installs the package, enables the service

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

run_install() {
  env "${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/install-tailscale.sh" \
    >"$test_root/install-output.log" 2>&1
}

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-tailscale.sh failed on a fresh machine'
fi

grep -Fq 'sudo dnf install -y dnf5-plugins' "$test_root/commands.log"
grep -Fq \
  'sudo dnf config-manager addrepo --overwrite --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo' \
  "$test_root/commands.log"
grep -Fq 'sudo dnf install -y tailscale' "$test_root/commands.log"
grep -Fq 'sudo systemctl enable --now tailscaled' "$test_root/commands.log"
[[ -f "$test_root/etc/yum.repos.d/tailscale.repo" ]] ||
  fail_with_context 'Tailscale repo file was not created'
grep -Fqx tailscaled "$test_root/enabled-units"
grep -Fqx tailscaled "$test_root/active-units"

if grep -Fq -- '--advertise' "$test_root/commands.log" ||
  grep -Fq 'tailscale up' "$test_root/commands.log"; then
  fail_with_context \
    "install-tailscale.sh ran 'tailscale up' or an advertise-* flag" \
    "$test_root/commands.log"
fi

state_file="$test_root/xdg/dotfiles/tailscale.conf"
[[ -f "$state_file" ]] || fail_with_context "state file missing: $state_file"
grep -Fqx 'profile=tailscale' "$state_file"
grep -Fqx 'repo=pkgs.tailscale.com' "$state_file"
grep -Fqx 'service=tailscaled' "$state_file"

grep -Fq 'not connected to a tailnet yet' "$test_root/install-output.log"
grep -Fq 'sudo tailscale up' "$test_root/install-output.log"

printf 'PASS: fresh install adds the repo, package, and service\n'

# --- rerunning is safe: the repo is not re-added, state is unchanged -------

first_state="$(sha256sum "$state_file")"
first_repo="$(sha256sum "$test_root/etc/yum.repos.d/tailscale.repo")"
: >"$test_root/commands.log"

env "${test_environment[@]}" MOCK_DNF5_PLUGINS_INSTALLED=true \
  "$repo_root/platforms/fedora/scripts/install-tailscale.sh" \
  >"$test_root/install-output.log" 2>&1 ||
  fail_with_context 'rerun of install-tailscale.sh failed' \
    "$test_root/install-output.log"

second_state="$(sha256sum "$state_file")"
second_repo="$(sha256sum "$test_root/etc/yum.repos.d/tailscale.repo")"

[[ "$first_state" == "$second_state" ]] ||
  fail_with_context 'tailscale.conf changed on a no-op rerun'
[[ "$first_repo" == "$second_repo" ]] ||
  fail_with_context 'Tailscale repo file changed on a rerun'

if grep -Fq 'config-manager addrepo' "$test_root/commands.log"; then
  fail_with_context \
    'Rerun re-added the Tailscale repository even though it already existed' \
    "$test_root/commands.log"
fi
if grep -Fq 'dnf5-plugins' "$test_root/commands.log"; then
  fail_with_context \
    'Rerun reinstalled dnf5-plugins even though it was already present' \
    "$test_root/commands.log"
fi

printf 'PASS: rerunning on an already-installed and already-connected machine is a no-op for the repo\n'
rm -rf -- "$test_root"

# --- verify-tailscale.sh distinguishes not-installed/not-running/unauth/connected

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

rm -f "$test_root/bin/tailscale"
if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh" \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context 'verify-tailscale.sh must fail when tailscale is not installed' \
    "$test_root/verify-output.log"
fi
grep -Fq 'tailscale not found' "$test_root/verify-output.log"
printf 'PASS: verification distinguishes "not installed"\n'
rm -rf -- "$test_root"

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh" \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context 'verify-tailscale.sh must fail when tailscaled is not enabled/active' \
    "$test_root/verify-output.log"
fi
grep -Fq 'tailscaled is not enabled' "$test_root/verify-output.log"
grep -Fq 'tailscaled is not active' "$test_root/verify-output.log"
grep -Fq "skipping 'tailscale status'" "$test_root/verify-output.log"
printf 'PASS: verification distinguishes "service not running"\n'
rm -rf -- "$test_root"

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tailscaled\n' >"$test_root/enabled-units"
printf 'tailscaled\n' >"$test_root/active-units"

verify_output="$(env "${test_environment[@]}" MOCK_TAILSCALE_BACKEND_STATE=NeedsLogin \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh" 2>&1)" ||
  fail_with_context "verify-tailscale.sh must pass for an unauthenticated install:\n$verify_output"
grep -Fq 'installed but not logged in' <<<"$verify_output"
printf 'PASS: verification treats "installed but not logged in" as a valid state\n'
rm -rf -- "$test_root"

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tailscaled\n' >"$test_root/enabled-units"
printf 'tailscaled\n' >"$test_root/active-units"

verify_output="$(env "${test_environment[@]}" MOCK_TAILSCALE_BACKEND_STATE=Running \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh" 2>&1)" ||
  fail_with_context "verify-tailscale.sh must pass when connected:\n$verify_output"
grep -Fq 'authenticated and connected to a tailnet' <<<"$verify_output"
printf 'PASS: verification reports the authenticated/connected state\n'
rm -rf -- "$test_root"

# --- the repository's own signature policy is read back from DNF ------------
#
# The .repo file Tailscale publishes is installed verbatim, so its gpgcheck
# setting -- and any later edit to it -- becomes the machine's policy for a
# repository that installs root-privileged packages. Verification has to read
# that policy back off the machine rather than assume the fetched file was
# the one that is still there.

verify_with_installed_repository() {
  test_root="$(new_test_root)"
  mapfile -t test_environment < <(base_environment "$test_root")
  printf 'tailscaled\n' >"$test_root/enabled-units"
  printf 'tailscaled\n' >"$test_root/active-units"
  mkdir -p "$test_root/etc/yum.repos.d"
  printf '[tailscale]\nname=Tailscale stable\n' \
    >"$test_root/etc/yum.repos.d/tailscale.repo"

  run_capture env "${test_environment[@]}" MOCK_TAILSCALE_BACKEND_STATE=Running "$@" \
    "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
}

verify_with_installed_repository MOCK_TAILSCALE_GPGCHECK=1
assert_success
assert_contains "$TEST_OUTPUT" 'tailscale repository enforces package signatures'
rm -rf -- "$test_root"
printf 'PASS: an installed repository with gpgcheck=1 verifies clean\n'

verify_with_installed_repository MOCK_TAILSCALE_GPGCHECK=0
assert_failure
assert_contains "$TEST_OUTPUT" 'gpgcheck = 0'
assert_contains "$TEST_OUTPUT" 'install without signature verification'
assert_not_contains "$TEST_OUTPUT" 'Tailscale verification passed'
rm -rf -- "$test_root"
printf 'PASS: gpgcheck=0 on the installed repository fails verification by name\n'

# --- verification separates "not authenticated" from "could not determine" ---
#
# The three outcomes below must stay distinguishable. Anything in the third
# group (parser or payload problems) previously degraded into a warning or an
# "unrecognized state" note and still exited zero, which reported success for
# a machine whose tailnet state had never actually been read.

# Verify against an enabled, active daemon; every case below differs only in
# what the CLI reports back.
verify_with_active_daemon() {
  test_root="$(new_test_root)"
  mapfile -t test_environment < <(base_environment "$test_root")
  printf 'tailscaled\n' >"$test_root/enabled-units"
  printf 'tailscaled\n' >"$test_root/active-units"

  run_capture env "${test_environment[@]}" "$@" \
    "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
}

verify_with_active_daemon MOCK_TAILSCALE_BACKEND_STATE=SomeFutureState
assert_failure
assert_contains "$TEST_OUTPUT" \
  "reported a BackendState this verifier does not recognize: 'SomeFutureState'"
assert_not_contains "$TEST_OUTPUT" 'Tailscale verification passed'
rm -rf -- "$test_root"
printf 'PASS: an unrecognized BackendState cannot report verification passed\n'

verify_with_active_daemon MOCK_TAILSCALE_STATUS_RAW='{"BackendState":'
assert_failure
assert_contains "$TEST_OUTPUT" 'did not return parseable JSON'
assert_not_contains "$TEST_OUTPUT" 'Tailscale verification passed'
rm -rf -- "$test_root"
printf 'PASS: malformed status JSON fails verification\n'

verify_with_active_daemon MOCK_TAILSCALE_STATUS_RAW='{"Version":"1.80.0"}'
assert_failure
assert_contains "$TEST_OUTPUT" 'without a BackendState'
assert_not_contains "$TEST_OUTPUT" 'Tailscale verification passed'
rm -rf -- "$test_root"
printf 'PASS: status JSON without BackendState fails verification\n'

verify_with_active_daemon MOCK_TAILSCALE_STATUS_EXIT=1
assert_failure
assert_contains "$TEST_OUTPUT" "'tailscale status --json' failed"
rm -rf -- "$test_root"
printf 'PASS: a failing status call on an active daemon fails verification\n'

# --- the JSON parser is a checked dependency, not an assumption ------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tailscaled\n' >"$test_root/enabled-units"
printf 'tailscaled\n' >"$test_root/active-units"

run_capture env "${test_environment[@]}" "PATH=$(make_parserless_path "$test_root")" \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
assert_failure
assert_contains "$TEST_OUTPUT" 'jq not found'
assert_not_contains "$TEST_OUTPUT" 'Tailscale verification passed'
rm -rf -- "$test_root"
printf 'PASS: a missing JSON parser fails verification instead of passing\n'

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tailscaled\n' >"$test_root/enabled-units"
printf 'tailscaled\n' >"$test_root/active-units"
cat >"$test_root/bin/jq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$test_root/bin/jq"

run_capture env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
assert_failure
assert_contains "$TEST_OUTPUT" 'not executable/usable'
rm -rf -- "$test_root"
printf 'PASS: a present-but-unusable JSON parser fails verification\n'

# --- verification never authenticates or changes tailnet state -------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tailscaled\n' >"$test_root/enabled-units"
printf 'tailscaled\n' >"$test_root/active-units"

run_capture env "${test_environment[@]}" MOCK_TAILSCALE_BACKEND_STATE=NeedsLogin \
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
assert_success
assert_file_not_contains "$test_root/commands.log" 'tailscale up'
assert_file_not_contains "$test_root/commands.log" 'tailscale set'
assert_file_not_contains "$test_root/commands.log" 'tailscale login'
assert_file_contains "$test_root/commands.log" 'tailscale status --json'
rm -rf -- "$test_root"
printf 'PASS: verification only reads state; it never authenticates\n'

# --- the macOS verifier's probes are bounded -------------------------------
#
# Reading Tailscale's state on macOS runs a binary that talks to the
# application, and the application can be waiting on a permission prompt that
# no CI session can answer. The first real installation to reach this profile
# printed "Tailscale application is installed" and then nothing at all for a
# hundred minutes, until the job hit its own two-hour limit.
#
# The probe is driven here directly, rather than through the verifier, because
# the paths it resolves (/usr/local/bin/tailscale and the application bundle)
# are not overridable and faking them would test the faking. What has to hold
# is the probe's own contract: a command that never returns comes back anyway,
# and says which of the two it was.

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../platforms/macos/lib/macos.sh
source "$repo_root/platforms/macos/lib/macos.sh"

probe_output=""
probe_status=0
probe_output="$(DOTFILES_TAILSCALE_PROBE_TIMEOUT=10 macos_tailscale_probe \
  echo 'tailscale 1.2.3')" || probe_status=$?
((probe_status == 0)) ||
  fail_with_context "A probe of a command that answers returned $probe_status"
assert_eq 'tailscale 1.2.3' "$probe_output" 'probe output is passed through'
printf 'PASS: a probe passes through the output and status of a command that answers\n'

probe_status=0
DOTFILES_TAILSCALE_PROBE_TIMEOUT=6 macos_tailscale_probe sh -c 'exit 3' ||
  probe_status=$?
((probe_status == 3)) ||
  fail_with_context "A failing command should report its own status, got $probe_status"
printf 'PASS: a probe reports a real failure as a failure, not as a timeout\n'

# The suite bounds its own call as well, so a probe that stopped bounding
# anything fails this test rather than hanging the run the way the job did.
# `sleep 3600` is the command no bound would ever let finish.
probe_status=0
started="$(date +%s)"
timeout --signal=TERM --kill-after=5 60 \
  env DOTFILES_TAILSCALE_PROBE_TIMEOUT=2 bash -c "
    source '$repo_root/common/lib/common.sh'
    source '$repo_root/platforms/macos/lib/macos.sh'
    macos_tailscale_probe sleep 3600
  " || probe_status=$?
elapsed=$(($(date +%s) - started))
((elapsed < 30)) ||
  fail_with_context "The probe of a command that never returns took ${elapsed}s"
macos_tailscale_probe_timed_out "$probe_status" ||
  fail_with_context "A command that never returns should report a timeout, got $probe_status"
printf 'PASS: a probe of a command that never returns comes back, as a timeout\n'

# What the verifier does with that outcome: a warning naming it, so a machine
# whose Tailscale cannot answer is reported rather than waited on.
assert_file_contains "$repo_root/platforms/macos/scripts/verify.sh" \
  'macos_tailscale_probe_timed_out "$version_status"'
assert_file_contains "$repo_root/platforms/macos/scripts/verify.sh" \
  'macos_tailscale_probe_timed_out "$status_probe"'
printf 'PASS: the macOS verifier handles a probe that did not answer\n'

# --- the macOS installer's closing guidance reflects the machine ------------
#
# The macOS installer ends by telling the person what is still left to do. It
# used to print the fresh-install to-do list unconditionally, so a machine that
# was already signed in, with the command-line tool already on PATH, was told
# it was not connected and offered a tool it already had. Each case below is a
# mocked Apple Silicon machine: Homebrew and `open` are fixtures, the
# application bundle lives in a temporary directory selected through
# MACOS_APPLICATIONS_DIR, and the command-line tool on PATH is a second fixture
# that is only put on PATH when the case says the person enabled it. Both
# answer `status --json` from the case's environment and log every call.

new_macos_root() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/bin" "$root/cli" "$root/config" "$root/home" \
    "$root/applications/Tailscale.app/Contents/MacOS"
  : >"$root/commands.log"

  cat >"$root/bin/brew" <<'EOF'
#!/usr/bin/env bash
printf 'brew %s\n' "$*" >>"$COMMAND_LOG"
[[ "${1:-}" != --prefix ]] || printf '/opt/homebrew\n'
exit 0
EOF

  cat >"$root/bin/open" <<'EOF'
#!/usr/bin/env bash
printf 'open %s\n' "$*" >>"$COMMAND_LOG"
EOF

  # One fixture serves as both tools. MOCK_<WHICH>_* picks each one's answer,
  # so a case can make the tool on PATH and the bundle disagree.
  local which
  for which in path bundle; do
    cat >"$root/tailscale-$which" <<EOF
#!/usr/bin/env bash
which=$which
EOF
    cat >>"$root/tailscale-$which" <<'EOF'
printf 'tailscale[%s] %s\n' "$which" "$*" >>"$COMMAND_LOG"
prefix="MOCK_${which^^}"
state_var="${prefix}_STATE" exit_var="${prefix}_EXIT"
raw_var="${prefix}_RAW" hang_var="${prefix}_HANG"
[[ "$*" == 'status --json' ]] || exit 0
[[ "${!hang_var:-false}" != true ]] || exec sleep 3600
[[ "${!exit_var:-0}" == 0 ]] || exit "${!exit_var}"
if [[ -n "${!raw_var:-}" ]]; then
  printf '%s\n' "${!raw_var}"
else
  printf '{"BackendState":"%s","Self":{"Online":true}}\n' "${!state_var:-NeedsLogin}"
fi
EOF
  done
  cp "$root/tailscale-bundle" \
    "$root/applications/Tailscale.app/Contents/MacOS/Tailscale"
  cp "$root/tailscale-path" "$root/cli/tailscale"
  chmod +x "$root/bin"/* "$root/cli/tailscale" \
    "$root/applications/Tailscale.app/Contents/MacOS/Tailscale"
  printf '%s\n' "$root"
}

# run_macos_installer <root> <with-path-cli: true|false> [VAR=value ...]
run_macos_installer() {
  local root="$1" with_path_cli="$2"
  shift 2
  local search_path="$PATH"
  [[ "$with_path_cli" != true ]] || search_path="$root/cli:$search_path"
  run_capture timeout --signal=TERM --kill-after=5 60 env \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "PATH=$root/bin:$search_path" \
    "COMMAND_LOG=$root/commands.log" \
    "HOMEBREW_BIN=$root/bin/brew" \
    "MACOS_APPLICATIONS_DIR=$root/applications" \
    "DOTFILES_TEST_UNAME_S=Darwin" \
    "DOTFILES_TEST_UNAME_M=arm64" \
    "DOTFILES_TEST_MACOS=true" \
    "DOTFILES_TAILSCALE_PROBE_TIMEOUT=2" \
    "$@" \
    "$repo_root/platforms/macos/scripts/install-tailscale.sh"
}

# assert_full_guidance: the interactive steps a fresh install needs.
assert_full_guidance() {
  assert_contains "$TEST_OUTPUT" 'Finish setup interactively:'
  assert_contains "$TEST_OUTPUT" 'Approve the Network Extension permission prompt'
  assert_contains "$TEST_OUTPUT" 'sign in to your tailnet'
  assert_not_contains "$TEST_OUTPUT" 'Nothing is left to set up'
}

assert_no_setup_steps() {
  assert_not_contains "$TEST_OUTPUT" 'Finish setup interactively:'
  assert_not_contains "$TEST_OUTPUT" 'Approve the Network Extension'
  assert_not_contains "$TEST_OUTPUT" 'not connected yet'
}

assert_cli_offered() {
  local root="$1"
  assert_contains "$TEST_OUTPUT" 'Optional: enable the command-line tool'
  assert_contains "$TEST_OUTPUT" \
    "$root/applications/Tailscale.app/Contents/MacOS/Tailscale status"
}

# assert_only_read <root>: the installer asked for state and nothing else. It
# never signs in, brings the tailnet up or changes a setting for the person.
assert_only_read() {
  local root="$1"
  assert_file_not_contains "$root/commands.log" ' up'
  assert_file_not_contains "$root/commands.log" ' login'
  assert_file_not_contains "$root/commands.log" ' set'
  if grep -F 'tailscale[' "$root/commands.log" | grep -Fv 'status --json'; then
    fail_with_context 'The macOS installer ran a tailscale command other than a status read'
  fi
}

# A fresh install: only the application bundle, nothing signed in. This is the
# case the original guidance was written for, and it must still get all of it.
root="$(new_macos_root)"
run_macos_installer "$root" false MOCK_BUNDLE_STATE=NeedsLogin
assert_success
assert_contains "$TEST_OUTPUT" 'Tailscale is installed but not connected yet (it reports NeedsLogin).'
assert_full_guidance
assert_cli_offered "$root"
assert_contains "$TEST_OUTPUT" 'No account/tailnet policy is set by this installer.'
assert_file_contains "$root/commands.log" 'brew install --cask tailscale-app'
assert_file_contains "$root/commands.log" 'tailscale[bundle] status --json'
assert_only_read "$root"
rm -rf -- "$root"
printf 'PASS: macOS fresh install gets the full interactive guidance\n'

# The machine the wrong guidance was reported from: connected, with the
# command-line tool already on PATH. Nothing is left, and it says so.
root="$(new_macos_root)"
run_macos_installer "$root" true MOCK_PATH_STATE=Running MOCK_BUNDLE_STATE=Running
assert_success
assert_contains "$TEST_OUTPUT" 'Tailscale is connected to a tailnet and the tailscale command is'
assert_contains "$TEST_OUTPUT" "available at $root/cli/tailscale. Nothing is left to set up."
assert_no_setup_steps
assert_not_contains "$TEST_OUTPUT" 'Optional: enable the command-line tool'
assert_not_contains "$TEST_OUTPUT" 'Until then'
assert_file_contains "$root/commands.log" 'tailscale[path] status --json'
assert_file_not_contains "$root/commands.log" 'tailscale[bundle]'
assert_only_read "$root"
rm -rf -- "$root"
printf 'PASS: macOS connected machine with the CLI on PATH is told nothing is left\n'

# Connected through the bundle, but the command-line tool was never enabled:
# only the optional tool is still outstanding.
root="$(new_macos_root)"
run_macos_installer "$root" false MOCK_BUNDLE_STATE=Running
assert_success
assert_contains "$TEST_OUTPUT" 'Tailscale is connected to a tailnet.'
assert_no_setup_steps
assert_cli_offered "$root"
assert_not_contains "$TEST_OUTPUT" 'Nothing is left to set up'
rm -rf -- "$root"
printf 'PASS: macOS connected machine without the CLI is offered only the CLI\n'

# The command-line tool is enabled but nobody is signed in: the sign-in steps
# remain, and the tool is reported rather than offered.
root="$(new_macos_root)"
run_macos_installer "$root" true MOCK_PATH_STATE=NeedsLogin
assert_success
assert_contains "$TEST_OUTPUT" 'not connected yet (it reports NeedsLogin).'
assert_full_guidance
assert_contains "$TEST_OUTPUT" "The tailscale command is available at $root/cli/tailscale."
assert_not_contains "$TEST_OUTPUT" 'Optional: enable the command-line tool'
rm -rf -- "$root"
printf 'PASS: macOS signed-out machine with the CLI keeps the sign-in steps only\n'

# Both places are checked: a tool on PATH that cannot answer does not stand in
# for the bundle, which is asked next.
root="$(new_macos_root)"
run_macos_installer "$root" true MOCK_PATH_EXIT=1 MOCK_BUNDLE_STATE=Running
assert_success
assert_file_contains "$root/commands.log" 'tailscale[path] status --json'
assert_file_contains "$root/commands.log" 'tailscale[bundle] status --json'
assert_contains "$TEST_OUTPUT" 'Nothing is left to set up.'
rm -rf -- "$root"
printf 'PASS: macOS falls back to the bundle when the CLI on PATH fails\n'

# Detection must never fail the step. Every way the state can go unread ends
# in success with the full, conservative guidance, and names what went wrong.
root="$(new_macos_root)"
started="$(date +%s)"
run_macos_installer "$root" true MOCK_PATH_HANG=true MOCK_BUNDLE_STATE=Running
elapsed=$(($(date +%s) - started))
assert_success
((elapsed < 30)) ||
  fail_with_context "The installer waited ${elapsed}s on a status probe that never answers"
assert_contains "$TEST_OUTPUT" 'its connection state could not be read'
assert_contains "$TEST_OUTPUT" "'tailscale status --json' did not answer within 2s"
assert_full_guidance
# The application is what is not answering, so it is not asked a second time.
assert_file_not_contains "$root/commands.log" 'tailscale[bundle]'
rm -rf -- "$root"
printf 'PASS: macOS status probe that hangs is bounded and falls back to full guidance\n'

root="$(new_macos_root)"
run_macos_installer "$root" true MOCK_PATH_EXIT=1 MOCK_BUNDLE_EXIT=1
assert_success
assert_contains "$TEST_OUTPUT" "its connection state could not be read"
assert_contains "$TEST_OUTPUT" "'tailscale status --json' failed"
assert_full_guidance
rm -rf -- "$root"
printf 'PASS: macOS status probe that fails falls back to full guidance\n'

root="$(new_macos_root)"
run_macos_installer "$root" false MOCK_BUNDLE_RAW='not json'
assert_success
assert_contains "$TEST_OUTPUT" 'did not report a BackendState'
assert_full_guidance
rm -rf -- "$root"
printf 'PASS: macOS malformed status output falls back to full guidance\n'

root="$(new_macos_root)"
run_macos_installer "$root" false MOCK_BUNDLE_STATE=SomethingNew
assert_success
assert_contains "$TEST_OUTPUT" 'unrecognized BackendState: SomethingNew'
assert_full_guidance
rm -rf -- "$root"
printf 'PASS: macOS unrecognized backend state falls back to full guidance\n'

root="$(new_macos_root)"
rm -- "$root/applications/Tailscale.app/Contents/MacOS/Tailscale"
run_macos_installer "$root" false
assert_success
assert_contains "$TEST_OUTPUT" 'no Tailscale command-line tool was found to ask'
assert_full_guidance
assert_contains "$TEST_OUTPUT" 'Optional: enable the command-line tool'
assert_not_contains "$TEST_OUTPUT" 'Until then'
rm -rf -- "$root"
printf 'PASS: macOS with no command-line tool anywhere falls back to full guidance\n'

# --- repository hygiene: no embedded credentials -----------------------
#
# Flag names like --advertise-exit-node or --accept-routes are expected to
# appear in prose (documenting what this profile deliberately does not do),
# so only credential-shaped literals are banned here. That the installer
# never actually executes 'tailscale up'/'tailscale set' is instead proven
# behaviorally above: the fresh-install test's mock command log captures
# every real invocation of the tailscale binary, and asserts neither
# appears in it.

forbidden_pattern='tskey-|--authkey|--auth-key'
tailscale_scripts=(
  "$repo_root/platforms/fedora/scripts/install-tailscale.sh"
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
  "$repo_root/platforms/fedora/lib/tailscale.sh"
  "$repo_root/platforms/macos/scripts/install-tailscale.sh"
  "$repo_root/platforms/fedora/scripts/install-tailscale.sh"
  "$repo_root/platforms/fedora/scripts/verify-tailscale.sh"
)

if grep -E -n "$forbidden_pattern" "${tailscale_scripts[@]}"; then
  fail_with_context \
    'A Tailscale profile script embeds a credential-shaped literal'
fi

printf 'PASS: no embedded credentials in the profile scripts\n'

printf '\nTailscale profile install, verification, and idempotency tests passed.\n'
