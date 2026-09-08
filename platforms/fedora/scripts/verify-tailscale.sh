#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

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

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $(command -v "$command_name")"
  else
    fail "$command_name not found"
  fi
}

# This never touches the network, never requires an interactive login, and
# never mutates tailnet/account state: it only inspects the locally
# installed CLI, the systemd unit, and the daemon's own already-reported
# backend state.

section "Tailscale commands"
check_command tailscale

if ((failures > 0)); then
  printf '\n\033[1;31mTailscale verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

section "tailscaled service"

service_active="false"
if systemctl is-enabled --quiet tailscaled 2>/dev/null; then
  pass "tailscaled is enabled"
else
  fail "tailscaled is not enabled"
fi

if systemctl is-active --quiet tailscaled 2>/dev/null; then
  pass "tailscaled is active"
  service_active="true"
else
  fail "tailscaled is not active"
fi

section "Tailscale version"

if version_output="$(tailscale version 2>&1)"; then
  pass "tailscale version"
  printf '%s\n' "$version_output" | head -n1 | sed 's/^/  /'
else
  fail "tailscale version failed"
fi

section "Tailnet connection state"

if [[ "$service_active" != "true" ]]; then
  warning "tailscaled is not active; skipping 'tailscale status' (the daemon is unreachable)"
else
  if status_json="$(tailscale status --json 2>/dev/null)"; then
    backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"

    case "$backend_state" in
    Running)
      pass "tailscale status: Running (authenticated and connected to a tailnet)"
      ;;
    NeedsLogin | NoState | Stopped | Starting | NeedsMachineAuth)
      pass "tailscale status: $backend_state (installed but not logged in;" \
        "run 'sudo tailscale up' to authenticate)"
      ;;
    *)
      warning "tailscale status reported an unrecognized BackendState: ${backend_state:-empty}"
      ;;
    esac
  else
    fail "'tailscale status --json' failed even though tailscaled is active"
  fi
fi

if ((failures > 0)); then
  printf '\n\033[1;31mTailscale verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

printf '\n\033[1;32mTailscale verification passed.\033[0m\n'
