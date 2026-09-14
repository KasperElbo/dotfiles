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
  mkdir -p "$test_root/etc"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/commands.log"

  # DNF uses the shared exact-argv contract so renamed packages or unexpected
  # package-manager flags fail this high-risk installer suite immediately.
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

if [[ "${1:-}" != --user ]]; then
  exit 0
fi
shift
cmd="${1:-}"
shift || true

case "$cmd" in
enable)
  for arg in "$@"; do
    case "$arg" in --*) continue ;; esac
    grep -qx "$arg" "$USER_ENABLED_UNITS" 2>/dev/null ||
      printf '%s\n' "$arg" >>"$USER_ENABLED_UNITS"
    grep -qx "$arg" "$USER_ACTIVE_UNITS" 2>/dev/null ||
      printf '%s\n' "$arg" >>"$USER_ACTIVE_UNITS"
  done
  ;;
is-enabled)
  args=("$@")
  grep -qx "${args[-1]}" "$USER_ENABLED_UNITS" 2>/dev/null
  exit $?
  ;;
is-active)
  args=("$@")
  grep -qx "${args[-1]}" "$USER_ACTIVE_UNITS" 2>/dev/null
  exit $?
  ;;
esac
exit 0
EOF

  cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$COMMAND_LOG"
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

# --- dry-run makes no changes -----------------------------------------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/install-containers.sh" --dry-run)"

assert_contains "$dry_run_output" 'podman'
assert_contains "$dry_run_output" 'podman-compose'
assert_contains "$dry_run_output" 'Buildah / Skopeo:      not installed'
assert_contains "$dry_run_output" 'Docker Engine/alias:   not installed'
assert_contains "$dry_run_output" 'Rootless API socket:   false'
assert_contains "$dry_run_output" \
  'allocate a fresh, non-overlapping subuid/subgid range for tester'
assert_contains "$dry_run_output" 'No changes were made.'

api_socket_dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/install-containers.sh" --dry-run --api-socket)"
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
    "$repo_root/scripts/install-containers.sh" \
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

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
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

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
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

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
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

verify_socket_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test 2>&1)"
assert_contains "$verify_socket_output" 'podman.socket is enabled'
assert_contains "$verify_socket_output" 'podman.socket is active'
printf 'PASS: --api-socket enables the rootless user-scoped API socket\n'

# --- verify-containers.sh --skip-smoke-test never touches containers -------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

assert_contains "$verify_output" 'podman version'
assert_contains "$verify_output" 'podman info reports rootless execution'
assert_contains "$verify_output" 'rootless network backend: netavark'
assert_contains "$verify_output" 'smoke test skipped'

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
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test \
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
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test \
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

smoke_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" 2>&1)" ||
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

printf 'PASS: full smoke test exercises every rootless workflow and cleans up\n'

# --- a smoke-test failure is reported and still exits non-zero -------------

new_test_root
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

if env "${test_environment[@]}" MOCK_PODMAN_BUILD_EXIT=1 \
  "$repo_root/scripts/verify-containers.sh" \
  >"$test_root/smoke-failure.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail when podman build fails' \
    "$test_root/smoke-failure.log"
fi
assert_file_contains "$test_root/smoke-failure.log" 'build failed'
printf 'PASS: a smoke-test failure is reported and fails verification\n'

printf '\nContainers profile install, verification, and idempotency tests passed.\n'
