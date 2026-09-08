#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

new_test_root() {
  local test_root
  test_root="$(mktemp -d)"

  local mock_bin="$test_root/bin"
  mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" "$test_root/etc"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/commands.log"

  cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
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

  cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
if [[ "$1" == dnf ]]; then
  exit 0
fi
"$@"
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

  printf '%s\n' "$test_root"
}

base_environment() {
  local test_root="$1"

  printf '%s\n' \
    "HOME=$test_root/home" \
    "XDG_CONFIG_HOME=$test_root/xdg" \
    "XDG_DATA_HOME=$test_root/home/.local/share" \
    "PATH=$test_root/bin:$PATH" \
    "COMMAND_LOG=$test_root/commands.log" \
    "OS_RELEASE_FILE=$test_root/os-release" \
    "SUBUID_FILE=$test_root/subuid" \
    "SUBGID_FILE=$test_root/subgid" \
    "USER_ENABLED_UNITS=$test_root/user-enabled-units" \
    "USER_ACTIVE_UNITS=$test_root/user-active-units" \
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

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/install-containers.sh" --dry-run)"

grep -Fq 'podman' <<<"$dry_run_output"
grep -Fq 'podman-compose' <<<"$dry_run_output"
grep -Fq 'Buildah / Skopeo:      not installed' <<<"$dry_run_output"
grep -Fq 'Docker Engine/alias:   not installed' <<<"$dry_run_output"
grep -Fq 'Rootless API socket:   false' <<<"$dry_run_output"
grep -Fq \
  'allocate a fresh, non-overlapping subuid/subgid range for tester' \
  <<<"$dry_run_output"
grep -Fq 'No changes were made.' <<<"$dry_run_output"

api_socket_dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/install-containers.sh" --dry-run --api-socket)"
grep -Fq 'Rootless API socket:   true' <<<"$api_socket_dry_run_output"
grep -Fq 'podman.socket' <<<"$api_socket_dry_run_output"

if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Dry-run executed a mutating command.' \
    "$test_root/commands.log"
fi
if [[ -s "$test_root/subuid" || -s "$test_root/subgid" ]]; then
  fail_with_context 'Dry-run changed subuid/subgid state.'
fi

rm -rf -- "$test_root"
printf 'PASS: dry-run reports the plan without mutating anything\n'

# --- fresh install allocates a subuid/subgid range, then reruns cleanly ----

test_root="$(new_test_root)"
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

grep -Fq 'sudo dnf install -y podman podman-compose' "$test_root/commands.log"
grep -Fq 'usermod --add-subuids 100000-165535 tester' "$test_root/commands.log"
grep -Fq 'usermod --add-subgids 100000-165535 tester' "$test_root/commands.log"
grep -Fq 'podman system migrate' "$test_root/commands.log"
grep -Fqx 'tester:100000:65536' "$test_root/subuid"
grep -Fqx 'tester:100000:65536' "$test_root/subgid"

state_file="$test_root/xdg/dotfiles/containers.conf"
[[ -f "$state_file" ]] ||
  fail_with_context "state file missing: $state_file"
grep -Fqx 'profile=containers' "$state_file"
grep -Fqx 'runtime=podman' "$state_file"
grep -Fqx 'mode=rootless' "$state_file"
grep -Fqx 'compose_provider=podman-compose' "$state_file"
grep -Fqx 'api_socket=disabled' "$state_file"
grep -Fqx 'user=tester' "$state_file"

first_state="$(sha256sum "$state_file")"
first_subuid="$(sha256sum "$test_root/subuid")"
: >"$test_root/commands.log"

if ! run_install; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'rerun of install-containers.sh failed'
fi

second_state="$(sha256sum "$state_file")"
second_subuid="$(sha256sum "$test_root/subuid")"

[[ "$first_state" == "$second_state" ]] ||
  fail_with_context 'containers.conf changed on a no-op rerun'
[[ "$first_subuid" == "$second_subuid" ]] ||
  fail_with_context '/etc/subuid changed on a no-op rerun'

if grep -Fq 'usermod --add-subuids' "$test_root/commands.log"; then
  fail_with_context \
    'Rerun re-allocated a subuid range for a user that already has one' \
    "$test_root/commands.log"
fi
if grep -Fq 'podman system migrate' "$test_root/commands.log"; then
  fail_with_context \
    'Rerun called podman system migrate with no subuid/subgid change' \
    "$test_root/commands.log"
fi

printf 'PASS: fresh install allocates subuid/subgid once and reruns cleanly\n'
rm -rf -- "$test_root"

# --- an existing subuid/subgid range is left untouched and not reallocated -

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

printf 'other-user:100000:65536\n' >"$test_root/subuid"
printf 'other-user:100000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed with an existing range'
fi

grep -Fqx 'other-user:100000:65536' "$test_root/subuid"
grep -Fqx 'tester:165536:65536' "$test_root/subuid"
grep -Fqx 'tester:165536:65536' "$test_root/subgid"
printf 'PASS: a new user is allocated a non-overlapping subuid/subgid range\n'
rm -rf -- "$test_root"

# --- a user who already owns both ranges is never touched ------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:200000:65536\n' >"$test_root/subuid"
printf 'tester:200000:65536\n' >"$test_root/subgid"

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed for an already-provisioned user'
fi

if grep -Fq 'usermod' "$test_root/commands.log"; then
  fail_with_context \
    'usermod was called for a user that already had both ranges' \
    "$test_root/commands.log"
fi
grep -Fqx 'tester:200000:65536' "$test_root/subuid"
printf 'PASS: an already-provisioned user is left untouched\n'
rm -rf -- "$test_root"

# --- --api-socket enables the rootless, socket-activated user unit ---------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" "$repo_root/scripts/install-containers.sh" \
  --api-socket >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh --api-socket failed'
fi

grep -Fq 'systemctl --user enable --now podman.socket' \
  "$test_root/commands.log"
if grep -Eq 'sudo systemctl.*podman.socket' "$test_root/commands.log"; then
  fail_with_context \
    'The Podman API socket must be enabled in the user (--user) scope only' \
    "$test_root/commands.log"
fi
grep -Fqx 'podman.socket' "$test_root/user-enabled-units"
grep -Fqx 'api_socket=enabled' "$test_root/xdg/dotfiles/containers.conf"

verify_socket_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test 2>&1)"
grep -Fq 'podman.socket is enabled' <<<"$verify_socket_output"
grep -Fq 'podman.socket is active' <<<"$verify_socket_output"
printf 'PASS: --api-socket enables the rootless user-scoped API socket\n'
rm -rf -- "$test_root"

# --- verify-containers.sh --skip-smoke-test never touches containers -------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

grep -Fq 'podman version' <<<"$verify_output"
grep -Fq 'podman info reports rootless execution' <<<"$verify_output"
grep -Fq 'rootless network backend: netavark' <<<"$verify_output"
grep -Fq 'smoke test skipped' <<<"$verify_output"

if grep -Eq 'podman (pull|build|volume create|network create)' \
  "$test_root/commands.log"; then
  fail_with_context \
    '--skip-smoke-test still ran mutating container operations' \
    "$test_root/commands.log"
fi
printf 'PASS: --skip-smoke-test performs inspection only\n'
rm -rf -- "$test_root"

# --- a non-rootless podman is reported as a verification failure -----------

test_root="$(new_test_root)"
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
grep -Fq 'does not report rootless execution' "$test_root/verify-output.log"
printf 'PASS: verification fails when Podman is not rootless\n'
rm -rf -- "$test_root"

# --- missing subuid/subgid ranges are reported as verification failures ----

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-output.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without a subuid/subgid range' \
    "$test_root/verify-output.log"
fi
grep -Fq 'has no subuid range' "$test_root/verify-output.log"
grep -Fq 'has no subgid range' "$test_root/verify-output.log"
printf 'PASS: verification fails without a subuid/subgid range\n'
rm -rf -- "$test_root"

# --- full smoke test: happy path exercises pull/run/build/mounts/port/net/compose

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

smoke_output="$(env "${test_environment[@]}" \
  "$repo_root/scripts/verify-containers.sh" 2>&1)" ||
  fail_with_context "full smoke test failed:\n$smoke_output"

grep -Fq 'pull: docker.io/library/busybox:stable' <<<"$smoke_output"
grep -Fq 'run: minimal container executes and exits cleanly' <<<"$smoke_output"
grep -Fq 'build: Containerfile builds and the built image runs' <<<"$smoke_output"
grep -Fq 'bind mount: SELinux-labeled (:Z) host directory is readable' \
  <<<"$smoke_output"
grep -Fq 'named volume: data persists across containers' <<<"$smoke_output"
grep -Fq 'localhost port publishing:' <<<"$smoke_output"
grep -Fq 'container networking:' <<<"$smoke_output"
grep -Fq 'compose: multi-service project reachable' <<<"$smoke_output"
grep -Fq 'Containers verification passed.' <<<"$smoke_output"

grep -Fq -- '-v ' "$test_root/commands.log"
grep -Fq ':Z' "$test_root/commands.log"
grep -Fq -- '-p 127.0.0.1:' "$test_root/commands.log"
grep -Fq -- '--network' "$test_root/commands.log"
grep -Fq 'podman compose' "$test_root/commands.log"

printf 'PASS: full smoke test exercises every rootless workflow and cleans up\n'
rm -rf -- "$test_root"

# --- a smoke-test failure is reported and still exits non-zero -------------

test_root="$(new_test_root)"
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
grep -Fq 'build failed' "$test_root/smoke-failure.log"
printf 'PASS: a smoke-test failure is reported and fails verification\n'
rm -rf -- "$test_root"

printf '\nContainers profile install, verification, and idempotency tests passed.\n'
