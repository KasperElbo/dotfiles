#!/usr/bin/env bash

# Bounded, integrity-checked network transfers for repository-controlled
# downloads.
#
# This library deliberately does not select shell options: sourcing a shared
# library must never change the caller's errexit/nounset/pipefail policy. It
# needs info/warn/die and ensure_dir from lib/common.sh, and sources that
# itself, so it is correct sourced standalone.
#
# Scope and safety boundary
# -------------------------
# Everything here performs a *safe, idempotent* HTTPS GET into a file. That is
# the only class of operation this repository retries automatically. Package
# manager transactions, remote scripts, and any other command whose retry can
# duplicate a side effect are never retried by this library, and must never be
# routed through it.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

DOTFILES_FETCH_CONNECT_TIMEOUT="${DOTFILES_FETCH_CONNECT_TIMEOUT:-10}"
# A reachability probe is not a transfer: it is bounded far more tightly, so
# an offline machine is told in seconds rather than after a download budget.
# The two bounds are separate on purpose. The connect bound is what decides
# "this host does not answer"; the total ceiling bounds the whole operation,
# the connection included, and is set well above the connect bound so that a
# host which answers slowly still finishes the probe rather than being called
# unreachable.
DOTFILES_FETCH_PROBE_TIMEOUT="${DOTFILES_FETCH_PROBE_TIMEOUT:-5}"
DOTFILES_FETCH_PROBE_MAX_TIME="${DOTFILES_FETCH_PROBE_MAX_TIME:-20}"
DOTFILES_FETCH_MAX_TIME="${DOTFILES_FETCH_MAX_TIME:-120}"
DOTFILES_FETCH_ATTEMPTS="${DOTFILES_FETCH_ATTEMPTS:-3}"
DOTFILES_FETCH_RETRY_DELAY="${DOTFILES_FETCH_RETRY_DELAY:-2}"

fetch_policy_description() {
  printf 'connect-timeout=%ss total-timeout=%ss attempts=%s initial-backoff=%ss\n' \
    "$DOTFILES_FETCH_CONNECT_TIMEOUT" "$DOTFILES_FETCH_MAX_TIME" \
    "$DOTFILES_FETCH_ATTEMPTS" "$DOTFILES_FETCH_RETRY_DELAY"
}

# fetch_sha256 <path>: portable SHA-256 of a file, printed bare.
fetch_sha256() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" | cut -d' ' -f1
  else
    printf 'No SHA-256 implementation found (sha256sum or shasum).\n' >&2
    return 1
  fi
}

# fetch_create_private_file <path>: create/truncate <path> readable only by the
# invoking user *before* any remote bytes land in it, so staged installer
# content is never briefly world-readable.
fetch_create_private_file() {
  local path="$1"

  : >"$path" || return 1
  chmod 600 -- "$path"
}

# fetch_to_file <url> <destination> [label]
#
# Bounded, retrying HTTPS GET. Retries only the transfer itself; a permanent
# failure exits with a single clear message naming the URL and the budget that
# was spent. The destination is mode 0600 for the whole transfer.
fetch_to_file() {
  local url="$1" destination="$2"
  local label="${3:-$url}"
  local attempt=1 delay="$DOTFILES_FETCH_RETRY_DELAY" status=0

  [[ "$url" == https://* ]] ||
    die "Refusing a non-HTTPS download for $label: $url"

  ensure_dir "$(dirname -- "$destination")"

  while :; do
    fetch_create_private_file "$destination" ||
      die "Could not create a private staging file: $destination"

    status=0
    curl --fail --show-error --silent --location \
      --proto '=https' --tlsv1.2 \
      --connect-timeout "$DOTFILES_FETCH_CONNECT_TIMEOUT" \
      --max-time "$DOTFILES_FETCH_MAX_TIME" \
      --output "$destination" \
      -- "$url" || status=$?

    if ((status == 0)) && [[ -s "$destination" ]]; then
      return 0
    fi

    if ((status == 0)); then
      # A 200 with a zero-length body is a failure for every source this
      # repository fetches; never let it reach a consumer as "success".
      warn "Download produced an empty file for $label (attempt $attempt/$DOTFILES_FETCH_ATTEMPTS)"
    else
      warn "Download failed for $label with curl status $status (attempt $attempt/$DOTFILES_FETCH_ATTEMPTS)"
    fi

    if ((attempt >= DOTFILES_FETCH_ATTEMPTS)); then
      rm -f -- "$destination"
      die "Giving up on $label after $DOTFILES_FETCH_ATTEMPTS attempt(s) (${DOTFILES_FETCH_MAX_TIME}s each): $url"
    fi

    attempt=$((attempt + 1))
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# fetch_host_reachable <url>
#
# True when a connection to the URL's host can be established. Nothing is
# transferred: the request asks for headers only and the body goes nowhere, so
# this is safe to run before a decision and repeat. Only a failure to resolve,
# to connect, to establish a verified TLS session, or to finish the
# headers-only request within the probe ceiling counts as unreachable -- an
# HTTP answer of any status means the network path works, and the real
# download reports its own error. curl is used rather than a raw socket
# precisely because it applies the same proxy and TLS settings the download
# will, so anything rejected here would have failed the download too.
#
# Exit status: 0 reachable, 1 unreachable.
fetch_host_reachable() {
  local url="$1"
  local status=0

  curl --silent --show-error --head --location \
    --proto '=https' --tlsv1.2 \
    --connect-timeout "$DOTFILES_FETCH_PROBE_TIMEOUT" \
    --max-time "$DOTFILES_FETCH_PROBE_MAX_TIME" \
    --output /dev/null \
    -- "$url" >/dev/null 2>&1 || status=$?

  # 5/6 name resolution, 7 connection refused or no route, 28 the connect
  # bound expired, or the probe as a whole outran the total ceiling,
  # 35 the TLS handshake itself failed, which a captive portal produces, and
  # 60 the peer's certificate did not verify, which an intercepting proxy
  # whose CA the trust store does not carry produces.
  case "$status" in
  5 | 6 | 7 | 28 | 35 | 60) return 1 ;;
  *) return 0 ;;
  esac
}

# fetch_verify_sha256 <path> <expected> <label>: hard-fail on mismatch.
fetch_verify_sha256() {
  local path="$1" expected="$2"
  local label="${3:-$path}"
  local actual

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
    die "Expected SHA-256 for $label is not a 64-character hex digest: $expected"

  actual="$(fetch_sha256 "$path")" ||
    die "Could not compute the SHA-256 of $label"

  [[ "$actual" == "$expected" ]] ||
    die "SHA-256 mismatch for $label: expected $expected, got $actual"
}

# fetch_assert_shell_script <path> <label>: reject content that is obviously
# not an installer script before anything executes it. This catches captive
# portals, error pages, and truncated binary transfers that still returned an
# HTTP 200. It cannot detect a truncated *text* script -- only a recorded
# digest can, which is why pinned sources are preferred over reviewed-live
# ones (see docs/supply-chain.md).
fetch_assert_shell_script() {
  local path="$1"
  local label="${2:-$path}"
  local first_line byte_count text_count

  [[ -s "$path" ]] || die "Downloaded $label is empty"

  # Binary content is never a shell installer. Counting bytes before and after
  # stripping NULs is portable; command substitution would drop them silently.
  byte_count="$(wc -c <"$path" | tr -d '[:space:]')"
  text_count="$(tr -d '\000' <"$path" | wc -c | tr -d '[:space:]')"
  [[ "$byte_count" == "$text_count" ]] ||
    die "Downloaded $label contains NUL bytes and is not a shell script"

  first_line=""
  while IFS= read -r first_line || [[ -n "$first_line" ]]; do
    [[ -z "${first_line//[[:space:]]/}" ]] || break
  done <"$path"

  case "$first_line" in
  '#'*) ;;
  *)
    die "Downloaded $label does not look like a shell script (first line: ${first_line:0:60})"
    ;;
  esac
}
