#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"
# shellcheck source=../lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/containers.sh"

failures=0

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

if ! require_fedora_wsl; then
  exit 1
fi

section "WSL container prerequisites"

if systemd_is_running; then
  pass "systemd is PID 1 (required by this profile for podman.socket and rootless cgroup v2 delegation)"
else
  fail "systemd is not PID 1; the containers profile requires it, see --help"
fi

if systemd_user_session_available; then
  pass "a systemd --user session (D-Bus bus) is reachable"
else
  fail "no systemd --user session is reachable; rootless networking (network create, builds that run the built image, Compose) needs it -- run: sudo loginctl enable-linger \"\$(id -un)\", then restart this WSL distribution"
fi

if cgroup_v2_available; then
  pass "cgroup v2 unified hierarchy is mounted"
else
  fail "cgroup v2 unified hierarchy not found"
fi

if user_namespaces_available; then
  pass "unprivileged user namespaces are enabled"
else
  fail "unprivileged user namespaces are disabled or unavailable"
fi

networking_mode_hint="$(wsl_networking_mode_hint)"
if [[ -n "$networking_mode_hint" ]]; then
  pass "networking: $networking_mode_hint (informational; podman's own container network is unaffected either way)"
fi

if [[ "$PWD" == /mnt/[a-zA-Z]/* ]]; then
  warning "current directory is under a Windows-mounted drive; bind mounts and SELinux relabeling behave differently there, run from the WSL Linux filesystem instead"
else
  pass "current directory is on the WSL Linux filesystem"
fi

if ((failures > 0)); then
  printf '\n\033[1;31mWSL container prerequisites failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-containers.sh" "$@"
