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
  test_stub_allow "$test_root" sudo dnf install -y dnf5-plugins
  test_stub_allow "$test_root" sudo dnf config-manager addrepo --overwrite \
    --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
  test_stub_allow "$test_root" sudo dnf install -y tailscale
  test_stub_allow "$test_root" sudo systemctl enable --now tailscaled
  test_stub_allow "$test_root" systemctl enable --now tailscaled
  test_stub_allow "$test_root" systemctl is-enabled --quiet tailscaled
  test_stub_allow "$test_root" systemctl is-active --quiet tailscaled

  cat >"$test_root/handlers/dnf" <<'EOF'
#!/usr/bin/env bash
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
