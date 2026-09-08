#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

new_test_root() {
  local test_root
  test_root="$(mktemp -d)"

  local mock_bin="$test_root/bin"
  mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" "$test_root/cgroup"
  : >"$test_root/subuid"
  : >"$test_root/subgid"
  : >"$test_root/user-enabled-units"
  : >"$test_root/user-active-units"
  : >"$test_root/commands.log"
  : >"$test_root/cgroup/cgroup.controllers"
  printf '65536\n' >"$test_root/max-user-namespaces"

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
    "CGROUP_ROOT=$test_root/cgroup" \
    "MAX_USER_NAMESPACES_FILE=$test_root/max-user-namespaces" \
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

test_root="$(new_test_root)"
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

printf 'PASS: cgroup v2 and user-namespace capability checks reflect the filesystem\n'
rm -rf -- "$test_root"

# --- require_wsl_containers_prereqs fails closed, before any mutation ------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-systemd.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without systemd as PID 1' \
    "$test_root/no-systemd.log"
fi
grep -Fq 'requires systemd as PID 1' "$test_root/no-systemd.log"
if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context \
    'A missing-systemd failure must not run any mutating command' \
    "$test_root/commands.log"
fi
printf 'PASS: install-containers.sh refuses to install without systemd\n'
rm -rf -- "$test_root"

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
rm -f "$test_root/cgroup/cgroup.controllers"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-cgroup.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without cgroup v2' \
    "$test_root/no-cgroup.log"
fi
grep -Fq 'cgroup v2 unified hierarchy not found' "$test_root/no-cgroup.log"
printf 'PASS: install-containers.sh refuses to install without cgroup v2\n'
rm -rf -- "$test_root"

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf '0\n' >"$test_root/max-user-namespaces"

if env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/no-userns.log" 2>&1; then
  fail_with_context \
    'install-containers.sh must fail closed without user namespaces' \
    "$test_root/no-userns.log"
fi
grep -Fq 'user namespaces are disabled' "$test_root/no-userns.log"
printf 'PASS: install-containers.sh refuses to install without user namespaces\n'
rm -rf -- "$test_root"

# --- --dry-run stays mutation-free and informative regardless of prereqs ---

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

dry_run_output="$(env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" --dry-run)"
grep -Fq 'Fedora WSL containers preflight' <<<"$dry_run_output"
grep -Fq 'Fedora containers (Podman) installation plan' <<<"$dry_run_output"
grep -Fq 'No changes were made.' <<<"$dry_run_output"

if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Dry-run executed a mutating command even without systemd' \
    "$test_root/commands.log"
fi
printf 'PASS: --dry-run reports the WSL plan without mutating anything, even without systemd\n'
rm -rf -- "$test_root"

# --- a satisfied WSL host installs cleanly through the shared Fedora logic -

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" \
  >"$test_root/install-output.log" 2>&1; then
  cat "$test_root/install-output.log" >&2
  fail_with_context 'install-containers.sh failed on a satisfied WSL host'
fi

grep -Fq 'sudo dnf install -y podman podman-compose' "$test_root/commands.log"
grep -Fqx 'tester:100000:65536' "$test_root/subuid"

state_file="$test_root/xdg/dotfiles/containers.conf"
[[ -f "$state_file" ]] || fail_with_context "state file missing: $state_file"
grep -Fqx 'runtime=podman' "$state_file"
printf 'PASS: a satisfied WSL host reuses the shared Fedora install logic unchanged\n'
rm -rf -- "$test_root"

# --- --validate delegates to the WSL verify wrapper ------------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

validate_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-containers.sh" --validate 2>&1)" ||
  true
grep -Fq 'WSL container prerequisites' <<<"$validate_output"
grep -Fq 'podman version' <<<"$validate_output"
printf 'PASS: --validate runs the WSL preflight and the shared verifier\n'
rm -rf -- "$test_root"

# --- verify-containers.sh fails closed before touching podman --------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" MOCK_PID1_COMM=bash \
  "$repo_root/platforms/fedora-wsl/scripts/verify-containers.sh" --skip-smoke-test \
  >"$test_root/verify-no-systemd.log" 2>&1; then
  fail_with_context \
    'verify-containers.sh must fail without systemd' \
    "$test_root/verify-no-systemd.log"
fi
grep -Fq 'systemd is not PID 1' "$test_root/verify-no-systemd.log"
if grep -Fq 'podman ' "$test_root/commands.log"; then
  fail_with_context \
    'A failed WSL preflight must not shell out to podman at all' \
    "$test_root/commands.log"
fi
printf 'PASS: verify-containers.sh fails closed before touching podman\n'
rm -rf -- "$test_root"

# --- verify-containers.sh reports a networking-mode hint and passes through

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf 'tester:100000:65536\n' >"$test_root/subuid"
printf 'tester:100000:65536\n' >"$test_root/subgid"

verify_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify-containers.sh" --skip-smoke-test 2>&1)" ||
  fail_with_context "verify-containers.sh --skip-smoke-test failed:\n$verify_output"

grep -Fq 'networking:' <<<"$verify_output"
grep -Fq 'single non-loopback IPv4 interface' <<<"$verify_output"
grep -Fq 'podman info reports rootless execution' <<<"$verify_output"
printf 'PASS: verify-containers.sh reports a networking-mode hint and reuses the shared verifier\n'
rm -rf -- "$test_root"

printf '\nFedora WSL containers preflight, install, and verification tests passed.\n'
