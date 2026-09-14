#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

new_test_root() {
  test_new_root
  test_root="$TEST_ROOT"

  local mock_bin="$test_root/bin"
  mkdir -p "$test_root/cgroup"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/commands.log"
  : >"$test_root/cgroup/cgroup.controllers"
  printf '65536\n' >"$test_root/max-user-namespaces"
  : >"$test_root/systemd-user-bus"

  test_stub_init "$test_root"
  test_stub_install "$test_root" dnf
  test_stub_allow "$test_root" dnf install -y podman podman-compose

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

  cat >"$mock_bin/ps" <<'EOF'
#!/usr/bin/env bash
# Mocks `ps -p 1 -o comm=`, the only invocation systemd_is_running makes.
if [[ "${1:-}" == -p && "${2:-}" == 1 ]]; then
  printf '%s\n' "${MOCK_PID1_COMM:-systemd}"
  exit 0
fi
exit 1
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

  cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
case "${1:-}" in
dnf | usermod)
  "$@"
  ;;
*)
  printf 'strict sudo fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
  ;;
esac
EOF

  cat >"$mock_bin/systemctl" <<'EOF'
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

  # Mirrors tests/test-containers.sh's mock: real enough to satisfy
  # verify-containers.sh's full pull/run/build/mount/network/Compose smoke
  # test, which the WSL wrapper delegates to unchanged.
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

  cat >"$mock_bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"addr show"* ]]; then
  printf '1: eth0    inet 172.20.0.5/20 brd 172.20.15.255 scope global eth0\n'
fi
exit 0
EOF

  chmod +x "$mock_bin"/*
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
    "CGROUP_ROOT=$root/cgroup" \
    "MAX_USER_NAMESPACES_FILE=$root/max-user-namespaces" \
    "SYSTEMD_USER_BUS_SOCKET=$root/systemd-user-bus" \
    "WSL_DISTRO_NAME=FedoraLinux" \
    "USER=tester"
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

# --- lib/containers.sh capability checks are independently testable --------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  cgroup_v2_available
'; then
  fail_with_context 'cgroup_v2_available must succeed when cgroup.controllers exists'
fi

if env "${test_environment[@]}" CGROUP_ROOT="$test_root/no-such-dir" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  cgroup_v2_available
'; then
  fail_with_context 'cgroup_v2_available must fail without cgroup.controllers'
fi

if ! env "${test_environment[@]}" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  user_namespaces_available
'; then
  fail_with_context 'user_namespaces_available must succeed when the file reports a positive count'
fi

printf '0\n' >"$test_root/max-user-namespaces"
if env "${test_environment[@]}" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  user_namespaces_available
'; then
  fail_with_context 'user_namespaces_available must fail when the count is 0'
fi

if ! env "${test_environment[@]}" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  systemd_user_session_available
'; then
  fail_with_context 'systemd_user_session_available must succeed when the bus socket exists'
fi

if env "${test_environment[@]}" SYSTEMD_USER_BUS_SOCKET="$test_root/no-such-bus" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/containers.sh"
  systemd_user_session_available
'; then
  fail_with_context \
    'systemd_user_session_available must fail without a reachable bus socket'
fi

printf 'PASS: cgroup v2, user-namespace, and systemd --user session capability checks reflect the filesystem\n'

# --- fixture contract keeps user and system service scope distinct ----------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

run_capture env "${test_environment[@]}" \
  systemctl --user enable --now podman.socket
assert_success
run_capture env "${test_environment[@]}" \
  systemctl --user is-enabled --quiet podman.socket
assert_success
run_capture env "${test_environment[@]}" \
  systemctl --user is-active --quiet podman.socket
assert_success
run_capture env "${test_environment[@]}" systemctl enable --now podman.socket
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict systemctl fixture rejected unsupported argv'
run_capture env "${test_environment[@]}" curl --head http://127.0.0.1:1/
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict curl fixture rejected unsupported argv'
printf 'PASS: container fixture rejects system-scope service calls and unsupported curl argv\n'

# --- require_wsl_containers_prereqs fails closed, before any mutation ------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-systemd.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without systemd as PID 1' \
    "$test_root/no-systemd.log"
fi
assert_file_contains "$test_root/no-systemd.log" 'requires systemd as PID 1'
assert_file_empty "$test_root/commands.log"
printf 'PASS: install-containers.sh refuses to install without systemd\n'

# --- systemd as PID 1 alone is not enough: a reachable --user session is ---
# --- also required (confirmed against a real Fedora WSL run) ---------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
rm -f "$test_root/systemd-user-bus"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-user-session.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without a systemd --user session, even with systemd as PID 1' \
    "$test_root/no-user-session.log"
fi
assert_file_contains "$test_root/no-user-session.log" 'no systemd --user session'
assert_file_contains "$test_root/no-user-session.log" 'loginctl enable-linger'
assert_file_empty "$test_root/commands.log"
printf 'PASS: install-containers.sh refuses to install without a reachable systemd --user session\n'

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
rm -f "$test_root/cgroup/cgroup.controllers"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-cgroup.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without cgroup v2' \
    "$test_root/no-cgroup.log"
fi
assert_file_contains "$test_root/no-cgroup.log" 'cgroup v2 unified hierarchy not found'
printf 'PASS: install-containers.sh refuses to install without cgroup v2\n'

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf '0\n' >"$test_root/max-user-namespaces"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-userns.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without user namespaces' \
    "$test_root/no-userns.log"
fi
assert_file_contains "$test_root/no-userns.log" 'user namespaces are disabled'
printf 'PASS: install-containers.sh refuses to install without user namespaces\n'

# --- --dry-run stays mutation-free and informative regardless of prereqs ---

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" --dry-run)"
assert_contains "$dry_run_output" 'Fedora WSL containers preflight'
assert_contains "$dry_run_output" 'Fedora containers (Podman) installation plan'
assert_contains "$dry_run_output" 'No changes were made.'
assert_file_empty "$test_root/commands.log"
printf 'PASS: --dry-run reports the WSL plan without mutating anything, even without systemd\n'

# --- a satisfied WSL host installs cleanly through the shared Fedora logic -

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed on a satisfied WSL host'
fi

assert_file_contains "$test_root/commands.log" 'sudo dnf install -y podman podman-compose'
test_stub_assert_called "$test_root" dnf install -y podman podman-compose
assert_file_line "$test_root/subuid" 'tester:100000:65536'

state_file="$test_root/config/dotfiles/containers.conf"
assert_path_exists "$state_file"
assert_file_line "$state_file" 'runtime=podman'
printf 'PASS: a satisfied WSL host reuses the shared Fedora install logic unchanged\n'

# --- --validate delegates to the WSL verify wrapper ------------------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

validate_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" --validate 2>&1)" ||
  true
assert_contains "$validate_output" 'WSL container prerequisites'
assert_contains "$validate_output" 'podman version'
printf 'PASS: --validate runs the WSL preflight and the shared verifier\n'

# --- verify-containers.sh fails closed before touching podman --------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-no-systemd.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without systemd' \
    "$test_root/verify-no-systemd.log"
fi
assert_file_contains "$test_root/verify-no-systemd.log" 'systemd is not PID 1'
assert_file_not_contains "$test_root/commands.log" 'podman '
printf 'PASS: verify-containers.sh fails closed before touching podman\n'

# --- verify-containers.sh also reports a missing systemd --user session ----

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
rm -f "$test_root/systemd-user-bus"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-no-user-session.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without a systemd --user session, even with systemd as PID 1' \
    "$test_root/verify-no-user-session.log"
fi
assert_file_contains "$test_root/verify-no-user-session.log" 'no systemd --user session'
assert_file_contains "$test_root/verify-no-user-session.log" 'loginctl enable-linger'
printf 'PASS: verify-containers.sh reports a missing systemd --user session\n'

# --- verify-containers.sh reports a networking-mode hint and passes through

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

assert_contains "$verify_output" 'networking:'
assert_contains "$verify_output" 'single non-loopback IPv4 interface'
assert_contains "$verify_output" 'podman info reports rootless execution'
printf 'PASS: verify-containers.sh reports a networking-mode hint and reuses the shared verifier\n'

printf '\nFedora WSL containers preflight, install, and verification tests passed.\n'