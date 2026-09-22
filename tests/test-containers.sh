#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# A real Unix socket, so the verifier's -S test is answered by the filesystem.
make_socket() {
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
' "$1"
}

new_test_root() {
  test_new_root
  test_root="$TEST_ROOT"

  local mock_bin="$test_root/bin"
  mkdir -p "$test_root/etc"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/system-enabled-units"
  : >"$test_root/system-active-units"
  : >"$test_root/commands.log"
  # The listen path systemctl reports for podman.socket, when a case sets one.
  : >"$test_root/user-socket-listen"
  # Owner names for the stat stub, as "<path>\t<owner>".
  : >"$test_root/stat-owners"
  # A real rootless runtime directory holding a real Unix socket, so the
  # verifier's own -S test and its mode reads answer from the filesystem
  # rather than from a fixture that could only ever say yes.
  mkdir -p "$test_root/runtime/podman"
  chmod 700 "$test_root/runtime/podman"
  make_socket "$test_root/runtime/podman/podman.sock"
  chmod 660 "$test_root/runtime/podman/podman.sock"

  # DNF uses the shared exact-argv contract so renamed packages or unexpected
  # package-manager flags fail this high-risk installer suite immediately.
  test_stub_init "$test_root"
  test_stub_install "$test_root" dnf
  test_stub_install "$test_root" sudo
  test_stub_install "$test_root" systemctl
  test_stub_allow "$test_root" dnf install -y podman podman-compose
  test_stub_allow "$test_root" sudo dnf install -y podman podman-compose
  test_stub_allow "$test_root" sudo usermod --add-subuids 100000-165535 tester
  test_stub_allow "$test_root" sudo usermod --add-subgids 100000-165535 tester
  test_stub_allow "$test_root" sudo usermod --add-subuids 165536-231071 tester
  test_stub_allow "$test_root" sudo usermod --add-subgids 165536-231071 tester
  test_stub_allow "$test_root" systemctl --user enable --now podman.socket
  test_stub_allow "$test_root" systemctl --user is-enabled --quiet podman.socket
  test_stub_allow "$test_root" systemctl --user is-active --quiet podman.socket
  test_stub_allow "$test_root" systemctl --user show podman.socket \
    --property=Listen
  # The verifier only consults the system scope to explain why a system-scoped
  # socket does not satisfy the user-scoped requirement; it is never enabled.
  test_stub_allow "$test_root" systemctl is-enabled --quiet podman.socket
  test_stub_allow "$test_root" systemctl is-active --quiet podman.socket

  # Modes come from the real filesystem, so a case sets one with chmod and the
  # verifier reads what is actually there. Only the owner name is answered from
  # a table: the suite runs as whoever invoked it while the verifier compares
  # against the stubbed `id -un`, and a test cannot chown without privileges.
  cat >"$mock_bin/stat" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == -c && "\${2:-}" == '%U' ]]; then
  path="\${3:-}"
  [[ -e "\$path" ]] || exit 1
  owner="\$(grep -F "\$path"\$'\t' "\$STAT_OWNERS" 2>/dev/null | head -1)" || true
  if [[ -n "\$owner" ]]; then
    printf '%s\n' "\${owner#*\$'\t'}"
  else
    printf '%s\n' tester
  fi
  exit 0
fi
exec $(type -P stat) "\$@"
EOF

  cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
-un) printf 'tester\n' ;;
*) printf 'tester\n' ;;
esac
EOF

  cat >"$mock_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$COMMAND_LOG"

subuid_range=""
subgid_range=""
user=""

while (($#)); do
  case "$1" in
  --add-subuids)
    subuid_range="$2"
    shift 2
    ;;
  --add-subgids)
    subgid_range="$2"
    shift 2
    ;;
  *)
    user="$1"
    shift
    ;;
  esac
done

if [[ -n "$subuid_range" ]]; then
  start="${subuid_range%-*}"
  end="${subuid_range#*-}"
  printf '%s:%s:%s\n' "$user" "$start" "$((end - start + 1))" >>"$SUBUID_FILE"
fi

if [[ -n "$subgid_range" ]]; then
  start="${subgid_range%-*}"
  end="${subgid_range#*-}"
  printf '%s:%s:%s\n' "$user" "$start" "$((end - start + 1))" >>"$SUBGID_FILE"
fi
EOF

  cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF

  cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"

if [[ $# -eq 4 && "$1" == --user && "$2" == enable &&
  "$3" == --now && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ENABLED_UNITS" 2>/dev/null ||
    printf 'podman.socket\n' >>"$USER_ENABLED_UNITS"
  grep -qx podman.socket "$USER_ACTIVE_UNITS" 2>/dev/null ||
    printf 'podman.socket\n' >>"$USER_ACTIVE_UNITS"
  exit 0
fi

if [[ $# -eq 4 && "$1" == --user && "$2" == is-enabled &&
  "$3" == --quiet && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ENABLED_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 4 && "$1" == --user && "$2" == is-active &&
  "$3" == --quiet && "$4" == podman.socket ]]; then
  grep -qx podman.socket "$USER_ACTIVE_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 4 && "$1" == --user && "$2" == show &&
  "$3" == podman.socket && "$4" == --property=Listen ]]; then
  # Empty unless a case records one, which is how the fallback to the default
  # rootless layout gets exercised as well as the resolved path.
  listen="$(cat "$USER_SOCKET_LISTEN" 2>/dev/null)"
  [[ -z "$listen" ]] || printf 'Listen=%s (Stream)\n' "$listen"
  exit 0
fi

if [[ $# -eq 3 && "$1" == is-enabled && "$2" == --quiet &&
  "$3" == podman.socket ]]; then
  grep -qx podman.socket "$SYSTEM_ENABLED_UNITS" 2>/dev/null
  exit $?
fi

if [[ $# -eq 3 && "$1" == is-active && "$2" == --quiet &&
  "$3" == podman.socket ]]; then
  grep -qx podman.socket "$SYSTEM_ACTIVE_UNITS" 2>/dev/null
  exit $?
fi

printf 'strict systemctl fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF

  cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$COMMAND_LOG"
if [[ $# -ne 2 || "$1" != -fsS || "$2" != http://127.0.0.1:*/* ]]; then
  printf 'strict curl fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
fi
if [[ "${MOCK_CURL_EXIT:-0}" == 0 ]]; then
  printf '%s' "${MOCK_CURL_OUTPUT-dotfiles-podman-smoke}"
fi
exit "${MOCK_CURL_EXIT:-0}"
EOF

  cat >"$mock_bin/podman-compose" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$mock_bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"$COMMAND_LOG"

subcommand="${1:-}"
shift || true

case "$subcommand" in
version)
  printf 'Client: Podman Engine\nVersion: 5.0.0\n'
  exit "${MOCK_PODMAN_VERSION_EXIT:-0}"
  ;;
info)
  for arg in "$@"; do
    case "$arg" in
    *Rootless*)
      printf '%s\n' "${MOCK_PODMAN_ROOTLESS:-true}"
      exit 0
      ;;
    *NetworkBackend*)
      printf '%s\n' "${MOCK_PODMAN_NETWORK_BACKEND:-netavark}"
      exit 0
      ;;
    esac
  done
  exit 0
  ;;
pull)
  exit "${MOCK_PODMAN_PULL_EXIT:-0}"
  ;;
build)
  exit "${MOCK_PODMAN_BUILD_EXIT:-0}"
  ;;
volume | network | stop | rmi | system)
  exit 0
  ;;
compose)
  exit "${MOCK_PODMAN_COMPOSE_EXIT:-0}"
  ;;
run)
  for arg in "$@"; do
    if [[ "$arg" == cat ]]; then
      printf '%s\n' "${MOCK_PODMAN_CAT_OUTPUT-dotfiles-podman-smoke}"
      exit "${MOCK_PODMAN_RUN_EXIT:-0}"
    fi
    if [[ "$arg" == wget ]]; then
      printf '%s' "${MOCK_PODMAN_WGET_OUTPUT-dotfiles-podman-smoke}"
      exit "${MOCK_PODMAN_RUN_EXIT:-0}"
    fi
  done
  exit "${MOCK_PODMAN_RUN_EXIT:-0}"
  ;;
*)
  exit 0
  ;;
esac
EOF

  chmod +x "$mock_bin"/* "$test_root/handlers"/*
  printf 'ID=fedora\n' >"$test_root/os-release"
}

base_environment() {
  local root="$1"
  test_env_args "$root"
  printf '%s\n' \
    "PATH=$root/bin:$PATH" \
    "COMMAND_LOG=$root/commands.log" \
    "OS_RELEASE_FILE=$root/os-release" \
    "SUBUID_FILE=$root/subuid" \
    "SUBGID_FILE=$root/subgid" \
    "USER_ENABLED_UNITS=$root/user-enabled-units" \
    "USER_ACTIVE_UNITS=$root/user-active-units" \
    "SYSTEM_ENABLED_UNITS=$root/system-enabled-units" \
    "SYSTEM_ACTIVE_UNITS=$root/system-active-units" \
    "USER_SOCKET_LISTEN=$root/user-socket-listen" \
    "STAT_OWNERS=$root/stat-owners" \
    "XDG_RUNTIME_DIR=$root/runtime" \
    "USER=tester"
}

# The installer records api_socket= in the containers profile state; the
# verifier checks the observed socket against it. Tests that exercise the
# verifier directly therefore have to record a selection, exactly as an
# install would.
write_containers_state() {
  local root="$1"
  local api_socket="$2"

  mkdir -p "$root/config/dotfiles"
  cat >"$root/config/dotfiles/containers.conf" <<EOF
schema_version=2
profile=containers
status=installed
runtime=podman
mode=rootless
compose_provider=podman-compose
api_socket=$api_socket
user=tester
EOF
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

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-containers.sh" --dry-run)"

assert_contains "$dry_run_output" 'podman'
assert_contains "$dry_run_output" 'podman-compose'
assert_contains "$dry_run_output" 'Buildah / Skopeo:      not installed'
assert_contains "$dry_run_output" 'Docker Engine/alias:   not installed'
assert_contains "$dry_run_output" 'Rootless API socket:   false'
assert_contains "$dry_run_output" \
  'allocate a fresh, non-overlapping subuid/subgid range for tester'
assert_contains "$dry_run_output" 'No changes were made.'

api_socket_dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-containers.sh" --dry-run --api-socket)"
assert_contains "$api_socket_dry_run_output" 'Rootless API socket:   true'
assert_contains "$api_socket_dry_run_output" 'podman.socket'

assert_file_empty "$test_root/commands.log"
assert_file_empty "$test_root/subuid"
assert_file_empty "$test_root/subgid"
printf 'PASS: dry-run reports the plan without mutating anything\n'

# --- fresh install allocates a subuid/subgid range, then reruns cleanly ----

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

run_install() {
  env "${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/install-containers.sh" \
    >"$test_root/install-output.log" 2>&1
}

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed on a fresh user'
fi

assert_file_contains "$test_root/commands.log" 'sudo dnf install -y podman podman-compose'
test_stub_assert_called "$test_root" dnf install -y podman podman-compose
assert_file_contains "$test_root/commands.log" 'usermod --add-subuids 100000-165535 tester'
assert_file_contains "$test_root/commands.log" 'usermod --add-subgids 100000-165535 tester'
assert_file_contains "$test_root/commands.log" 'podman system migrate'
assert_file_line "$test_root/subuid" 'tester:100000:65536'
assert_file_line "$test_root/subgid" 'tester:100000:65536'

state_file="$test_root/config/dotfiles/containers.conf"
assert_path_exists "$state_file"
assert_file_line "$state_file" 'profile=containers'
assert_file_line "$state_file" 'runtime=podman'
assert_file_line "$state_file" 'mode=rootless'
assert_file_line "$state_file" 'compose_provider=podman-compose'
assert_file_line "$state_file" 'api_socket=disabled'
assert_file_line "$state_file" 'user=tester'

first_state="$(sha256sum "$state_file")"
first_subuid="$(sha256sum "$test_root/subuid")"
: >"$test_root/commands.log"

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'rerun of install-containers.sh failed'
fi

second_state="$(sha256sum "$state_file")"
second_subuid="$(sha256sum "$test_root/subuid")"

assert_eq "$first_state" "$second_state" 'containers.conf changed on a no-op rerun'
assert_eq "$first_subuid" "$second_subuid" '/etc/subuid changed on a no-op rerun'
assert_file_not_contains "$test_root/commands.log" 'usermod --add-subuids'
assert_file_not_contains "$test_root/commands.log" 'podman system migrate'

printf 'PASS: fresh install allocates subuid/subgid once and reruns cleanly\n'

# --- an existing subuid/subgid range is left untouched and not reallocated -

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'other-user:100000:65536\n' >"$test_root/subuid"
printf 'other-user:100000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed with an existing range'
fi

assert_file_line "$test_root/subuid" 'other-user:100000:65536'
assert_file_line "$test_root/subuid" 'tester:165536:65536'
assert_file_line "$test_root/subgid" 'tester:165536:65536'
printf 'PASS: a new user is allocated a non-overlapping subuid/subgid range\n'

# --- a user who already owns both ranges is never touched ------------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:200000:65536\n' >"$test_root/subuid"
printf 'tester:200000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed for an already-provisioned user'
fi

assert_file_not_contains "$test_root/commands.log" 'usermod'
assert_file_line "$test_root/subuid" 'tester:200000:65536'
printf 'PASS: an already-provisioned user is left untouched\n'

# --- --api-socket enables the rootless, socket-activated user unit ---------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" "$repo_root/platforms/fedora/scripts/install-containers.sh" \
  --api-socket >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh --api-socket failed'
fi

assert_file_contains "$test_root/commands.log" \
  'systemctl --user enable --now podman.socket'
if grep -Eq 'sudo systemctl.*podman.socket' "$test_root/commands.log"; then
  fail_with_context \
    'The Podman API socket must be enabled in the user (--user) scope only' \
    "$test_root/commands.log"
fi
assert_file_line "$test_root/user-enabled-units" 'podman.socket'
assert_file_line "$test_root/config/dotfiles/containers.conf" 'api_socket=enabled'

run_capture env "${test_environment[@]}" systemctl enable --now podman.socket
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict stub rejected unsupported argv: systemctl'

verify_socket_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test 2>&1)"
assert_contains "$verify_socket_output" \
  'podman.socket is enabled and active for the user'
assert_contains "$verify_socket_output" 'as recorded'
printf 'PASS: --api-socket enables the rootless user-scoped API socket\n'

# --- recorded api_socket intent is what verification is measured against ---
#
# Before this contract the verifier passed whether the socket was enabled or
# disabled, so a run that asked for --api-socket and silently failed to
# establish it still verified clean. Each case below records an intent and
# then observes a socket state, so only the matching pair may pass.

# requested enabled + healthy user socket -> pass
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"
printf 'podman.socket\n' >"$test_root/user-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'podman.socket is enabled and active for the user'
printf 'PASS: recorded api_socket=enabled with a healthy user socket passes\n'

# --- the API socket is checked for owner and mode, not only for unit state --
#
# SEC-06: the section above reads a systemd unit state, which says the endpoint
# is running and nothing about the shape it is running in. The Podman API
# socket is equivalent to shell access -- anything that can talk to it can run
# a container with an arbitrary bind mount -- so these cases put a real socket
# on disk and read back what the verifier says about it.

socket_test_root() {
  new_test_root
  mapfile -t test_environment < <(base_environment "$test_root")
  printf 'tester:100000:65536\n' >"$test_root/subuid"
  printf 'tester:100000:65536\n' >"$test_root/subgid"
  write_containers_state "$test_root" enabled
  printf 'podman.socket\n' >"$test_root/user-enabled-units"
  printf 'podman.socket\n' >"$test_root/user-active-units"
  socket_path="$test_root/runtime/podman/podman.sock"
}

run_socket_verifier() {
  run_capture env "${test_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
}

# a user-owned 0660 socket in a 0700 directory -> pass, naming what it saw
socket_test_root

run_socket_verifier
assert_success
assert_contains "$TEST_OUTPUT" "$socket_path"
assert_contains "$TEST_OUTPUT" 'is owned by tester, mode 660'
assert_contains "$TEST_OUTPUT" 'is mode 700, so the API socket is reachable by tester only'
printf 'PASS: a healthy API socket is reported with its owner and its mode\n'

# a socket owned by another user -> fail, naming the owner
socket_test_root
printf '%s\t%s\n' "$socket_path" someone-else >"$test_root/stat-owners"

run_socket_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'is owned by someone-else, not tester'
printf 'PASS: an API socket owned by another user fails verification\n'

# a world-accessible socket -> fail, naming the mode
socket_test_root
chmod 666 "$socket_path"

run_socket_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'is mode 666, which is open to every user on this machine'
printf 'PASS: a world-accessible API socket fails verification\n'

# more than read and write for the group -> fail, naming the mode
socket_test_root
chmod 670 "$socket_path"

run_socket_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'is mode 670, which grants its group more than read and write'
printf 'PASS: an over-permissive group mode on the API socket fails\n'

# a directory anyone can walk into -> fail, whatever the socket's own mode is
socket_test_root
chmod 755 "$test_root/runtime/podman"

run_socket_verifier
assert_failure
assert_contains "$TEST_OUTPUT" 'is mode 755, so users other than tester can reach the API socket'
printf 'PASS: a world-readable directory around the API socket fails\n'
chmod 700 "$test_root/runtime/podman"

# the listen path comes from the unit, not from an assumption about the layout.
# The overridden socket is the healthy one and the default-layout socket is
# world-accessible, so a verifier that checked the assumed path would fail here
# and a verifier that named it would be caught naming it.
socket_test_root
mkdir -p "$test_root/elsewhere"
chmod 700 "$test_root/elsewhere"
make_socket "$test_root/elsewhere/overridden.sock"
chmod 660 "$test_root/elsewhere/overridden.sock"
chmod 666 "$socket_path"
printf '%s\n' "$test_root/elsewhere/overridden.sock" >"$test_root/user-socket-listen"

run_socket_verifier
assert_success
assert_contains "$TEST_OUTPUT" \
  "$test_root/elsewhere/overridden.sock (systemctl --user show podman.socket)"
assert_contains "$TEST_OUTPUT" 'is owned by tester, mode 660'
assert_not_contains "$TEST_OUTPUT" "$socket_path"
printf 'PASS: the API socket is checked where the unit says it listens\n'
chmod 660 "$socket_path"

# nothing at the resolved path -> unobserved, not a failure: an operator whose
# socket is somewhere this cannot see has not thereby got a broken profile
socket_test_root
rm -f "$socket_path"

run_socket_verifier
assert_success
assert_contains "$TEST_OUTPUT" 'is not a socket, so its owner and mode cannot be checked'
assert_contains "$TEST_OUTPUT" 'completed with unobserved checks'
printf 'PASS: an API socket that cannot be found is unobserved, not failed\n'

# api_socket=disabled -> there is no socket to check, so the section is silent
socket_test_root
write_containers_state "$test_root" disabled
: >"$test_root/user-enabled-units"
: >"$test_root/user-active-units"

run_socket_verifier
assert_success
assert_not_contains "$TEST_OUTPUT" 'API socket ownership and mode'
printf 'PASS: no API socket was asked for, so none is checked\n'

# requested enabled + socket never established -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'api_socket=enabled was recorded'
assert_contains "$TEST_OUTPUT" 'systemctl --user enable --now podman.socket'
printf 'PASS: recorded api_socket=enabled without the socket fails\n'

# requested enabled + enabled but not active (broken/unusable) -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'enabled but not active for the user'
printf 'PASS: an enabled-but-inactive user socket fails verification\n'

# a system-scoped socket cannot substitute for the user-scoped one
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" enabled
printf 'podman.socket\n' >"$test_root/system-enabled-units"
printf 'podman.socket\n' >"$test_root/system-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" \
  'a system-scoped podman.socket is present and does not satisfy this rootless profile'
printf 'PASS: a system-scoped socket does not satisfy the user-scoped requirement\n'

# requested disabled + disabled -> pass
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'podman.socket is not enabled, as recorded'
printf 'PASS: recorded api_socket=disabled with no socket passes\n'

# requested disabled + independently enabled -> warning, not failure
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled
printf 'podman.socket\n' >"$test_root/user-enabled-units"
printf 'podman.socket\n' >"$test_root/user-active-units"

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_success
assert_contains "$TEST_OUTPUT" 'api_socket=disabled was recorded, but'
assert_contains "$TEST_OUTPUT" 'passed with warnings'
printf 'PASS: an independently enabled socket is drift, reported as a warning\n'

# corrupt/unknown recorded state -> fail with a repair instruction
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
mkdir -p "$test_root/config/dotfiles"
cat >"$test_root/config/dotfiles/containers.conf" <<'EOF'
schema_version=2
profile=containers
status=installed
runtime=podman
mode=rootless
EOF

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'missing or invalid api_socket'
assert_contains "$TEST_OUTPUT" 'install-containers.sh'
printf 'PASS: corrupt recorded containers state fails with a repair instruction\n'

# selected in the install state but with no profile state at all -> fail
new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
mkdir -p "$test_root/state/dotfiles"
cat >"$test_root/state/dotfiles/install.conf" <<'EOF'
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=base,containers
observed_capabilities=base,containers
external_assurance=not-recorded
repository=local-checkout
revision=unknown
provenance=capability-manifest@unknown
EOF

run_capture env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test
assert_failure
assert_contains "$TEST_OUTPUT" 'the containers profile is selected in'
assert_contains "$TEST_OUTPUT" 'is missing'
printf 'PASS: a selected containers profile with no recorded state fails\n'

# --- verify-containers.sh --skip-smoke-test never touches containers -------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

assert_contains "$verify_output" 'podman version'
assert_contains "$verify_output" 'podman info reports rootless execution'
assert_contains "$verify_output" 'rootless network backend: netavark'
assert_contains "$verify_output" 'smoke test skipped'
# With nothing recorded there is no intent to measure against: that is
# reported as unobserved rather than silently passing the socket check.
assert_contains "$verify_output" 'no containers profile selection is recorded'
assert_contains "$verify_output" 'completed with unobserved checks'

if grep -Eq 'podman (pull|build|volume create|network create)' \
  "$test_root/commands.log"; then
  fail_with_context \
    '--skip-smoke-test still ran mutating container operations' \
    "$test_root/commands.log"
fi
printf 'PASS: --skip-smoke-test performs inspection only\n'

# --- a non-rootless podman is reported as a verification failure -----------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

if env "${test_environment[@]}" MOCK_PODMAN_ROOTLESS=false \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail when podman is not running rootless' \
    "$test_root/verify-output.log"
fi
assert_file_contains "$test_root/verify-output.log" 'does not report rootless execution'
printf 'PASS: verification fails when Podman is not rootless\n'

# --- missing subuid/subgid ranges are reported as verification failures ----

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without a subuid/subgid range' \
    "$test_root/verify-output.log"
fi
assert_file_contains "$test_root/verify-output.log" 'has no subuid range'
assert_file_contains "$test_root/verify-output.log" 'has no subgid range'
printf 'PASS: verification fails without a subuid/subgid range\n'

# --- full smoke test: happy path exercises pull/run/build/mounts/port/net/compose

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"
write_containers_state "$test_root" disabled

smoke_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" 2>&1)" ||
  fail_with_context "full smoke test failed:\n$smoke_output"

assert_contains "$smoke_output" 'pull: docker.io/library/busybox:stable'
assert_contains "$smoke_output" 'run: minimal container executes and exits cleanly'
assert_contains "$smoke_output" 'build: Containerfile builds and the built image runs'
assert_contains "$smoke_output" 'bind mount: SELinux-labeled (:Z) host directory is readable'
assert_contains "$smoke_output" 'named volume: data persists across containers'
assert_contains "$smoke_output" 'localhost port publishing:'
assert_contains "$smoke_output" 'container networking:'
assert_contains "$smoke_output" 'compose: multi-service project reachable'
assert_contains "$smoke_output" 'Containers verification passed.'

assert_file_contains "$test_root/commands.log" '-v '
assert_file_contains "$test_root/commands.log" ':Z'
assert_file_contains "$test_root/commands.log" '-p 127.0.0.1:'
assert_file_contains "$test_root/commands.log" '--network'
assert_file_contains "$test_root/commands.log" 'podman compose'

run_capture env "${test_environment[@]}" curl --head http://127.0.0.1:1/
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict curl fixture rejected unsupported argv'

printf 'PASS: full smoke test exercises every rootless workflow and cleans up\n'

# --- a smoke-test failure is reported and still exits non-zero -------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

if env "${test_environment[@]}" MOCK_PODMAN_BUILD_EXIT=1 \
  "$repo_root/platforms/fedora/scripts/verify-containers.sh" \
  >"$test_root/smoke-failure.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail when podman build fails' \
    "$test_root/smoke-failure.log"
fi
assert_file_contains "$test_root/smoke-failure.log" 'build failed'
printf 'PASS: a smoke-test failure is reported and fails verification\n'

printf '\nContainers profile install, verification, and idempotency tests passed.\n'
