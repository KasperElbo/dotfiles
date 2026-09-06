#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../common/lib/common.sh"
# shellcheck source=../platforms/fedora/lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../platforms/fedora/lib/secure-boot.sh"

mock_output=""
mock_status=0
mock_sudo_failure="false"
mock_regular_file=""
mock_existing_path=""

sudo() {
  if [[ "$mock_sudo_failure" == "true" ]]; then
    printf 'sudo: a password is required\n' >&2
    return 1
  fi

  if [[ "$1" == "test" ]]; then
    case "$2" in
    -f)
      [[ "$3" == "$mock_regular_file" ]]
      ;;
    -e)
      [[ "$3" == "$mock_existing_path" ]]
      ;;
    *)
      return 2
      ;;
    esac

    return
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

mock_sudo_failure="false"
mock_regular_file="/root-only/public_key.der"
mock_existing_path="/root-only/private_key.priv"

if [[ -f "$mock_regular_file" ]]; then
  printf 'restricted fixture unexpectedly exists for the unprivileged test\n' >&2
  exit 1
fi

if ! privileged_file_exists "$mock_regular_file"; then
  printf 'privileged regular-file check did not find its fixture\n' >&2
  exit 1
fi

if ! privileged_path_exists "$mock_existing_path"; then
  printf 'privileged path check did not find its fixture\n' >&2
  exit 1
fi

printf 'Secure Boot helper regression tests passed.\n'
