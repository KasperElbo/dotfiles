#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"

verify_reset

# This never touches the network, never requires an interactive login, and
# never mutates tailnet/account state: it only inspects the locally
# installed CLI, the systemd unit, and the daemon's own already-reported
# backend state.

section "Tailscale commands"
check_command tailscale

if ((VERIFY_FAILURES > 0)); then
  finish_verification "Tailscale verification"
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

# ---------------------------------------------------------------------------
# Tailnet connection state
#
# Three outcomes must stay distinguishable, because conflating them is what
# let a broken installation verify clean:
#
#   1. verified connected      -> pass
#   2. installed, not authenticated (a documented backend state) -> pass,
#      with the exact command needed to finish the connection
#   3. state could not be determined -> failure, never a warning
#
# (3) covers a missing or unusable parser, a status call that fails while the
# daemon is up, malformed JSON, an absent BackendState, and a backend state
# this verifier does not recognize: in each of those cases the verifier has
# not observed the connection state, so it must not claim it did.
#
# jq is part of the declared base package set for every platform that can
# select this profile, so it is checked as a dependency here rather than
# assumed usable -- the original false pass came from a platform that shipped
# without it.
# ---------------------------------------------------------------------------

section "Tailnet connection state"

if [[ "$service_active" != "true" ]]; then
  not_observed "tailscaled is not active; skipping 'tailscale status' (the" \
    "daemon is unreachable, so the tailnet connection state cannot be read)"
elif ! command_exists jq; then
  fail "jq not found; it is required to read 'tailscale status --json' and" \
    "is part of the base package set -- install it, then rerun"
elif ! jq --version >/dev/null 2>&1; then
  fail "jq is present but not executable/usable; the tailnet connection" \
    "state cannot be parsed"
elif ! status_json="$(tailscale status --json 2>/dev/null)"; then
  fail "'tailscale status --json' failed even though tailscaled is active"
elif ! backend_state="$(printf '%s' "$status_json" |
  jq -er '.BackendState' 2>/dev/null)"; then
  # jq -e exits non-zero for both a parse error and a null/absent field, so
  # separate them: the operator's next step differs.
  if printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
    fail "'tailscale status --json' returned JSON without a BackendState" \
      "field; the tailnet connection state could not be determined"
  else
    fail "'tailscale status --json' did not return parseable JSON; the" \
      "tailnet connection state could not be determined"
  fi
else
  case "$backend_state" in
  Running)
    pass "tailscale status: Running (authenticated and connected to a tailnet)"
    ;;
  NeedsLogin | NoState)
    pass "tailscale status: $backend_state (installed but not logged in;" \
      "run 'sudo tailscale up' to authenticate)"
    ;;
  Stopped)
    pass "tailscale status: Stopped (installed and configured but the client" \
      "is stopped; run 'sudo tailscale up' to reconnect)"
    ;;
  Starting)
    pass "tailscale status: Starting (installed; the client is still" \
      "bringing the tailnet connection up)"
    ;;
  NeedsMachineAuth)
    pass "tailscale status: NeedsMachineAuth (installed and authenticated;" \
      "approve this machine in the tailnet admin console)"
    ;;
  *)
    fail "tailscale status reported a BackendState this verifier does not" \
      "recognize: '$backend_state'. The connection state is therefore" \
      "unverified; update the supported backend states before trusting" \
      "this result"
    ;;
  esac
fi

finish_verification "Tailscale verification"
