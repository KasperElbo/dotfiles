#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/secure-boot.sh"

mock_output=""
mock_status=0
mock_sudo_failure="false"

sudo() {
  if [[ "$mock_sudo_failure" == "true" ]]; then
    printf 'sudo: a password is required\n' >&2
    return 1
  fi

  [[ "$1" == "env" && "$2" == "LC_ALL=C" && "$3" == "mokutil" ]]
  shift 3
  MOCK_PRIVILEGED="true" mokutil "$@"
}

mokutil() {
  if [[ "${MOCK_PRIVILEGED:-false}" != "true" ]]; then
    printf 'Failed to read MokListRT: Permission denied\n' >&2
    return 13
  fi

  printf '%s\n' "$mock_output"
  return "$mock_status"
}

assert_mok_state() {
  local description="$1"
  local output="$2"
  local status="$3"
  local expected="$4"

  mock_output="$output"
  mock_status="$status"
  mock_sudo_failure="false"

  probe_mok_key /tmp/test-public-key.der

  if [[ "$MOK_KEY_STATE" != "$expected" ]]; then
    printf '%s: expected %s, got %s\n' \
      "$description" "$expected" "$MOK_KEY_STATE" >&2
    exit 1
  fi
}

assert_mok_state \
  "enrolled key" \
  "/tmp/test-public-key.der is already enrolled" \
  0 \
  "enrolled"

assert_mok_state \
  "enrolled key with contradictory status" \
  "/tmp/test-public-key.der is already enrolled" \
  1 \
  "enrolled"

assert_mok_state \
  "enrolled key reported by status only" \
  "" \
  0 \
  "enrolled"

assert_mok_state \
  "pending key" \
  "/tmp/test-public-key.der is already in the enrollment request" \
  0 \
  "pending"

assert_mok_state \
  "unenrolled key" \
  "/tmp/test-public-key.der is not enrolled" \
  1 \
  "not-enrolled"

assert_mok_state \
  "blocked key" \
  "/tmp/test-public-key.der is blocked in dbx" \
  0 \
  "blocked"

mock_sudo_failure="true"
probe_mok_key /tmp/test-public-key.der

if [[ "$MOK_KEY_STATE" != "unknown" ]]; then
  printf 'sudo failure: expected unknown, got %s\n' "$MOK_KEY_STATE" >&2
  exit 1
fi

printf 'Secure Boot helper regression tests passed.\n'
