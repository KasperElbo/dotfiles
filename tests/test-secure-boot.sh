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
mock_sudo_argv=()

# The mock refuses -n the way sudo does once the timestamp has expired, rather
# than offering a flag the caller can read to find out. An interactive sudo in
# that state would block on a password prompt; a suite cannot wait for one, so
# it stands in for the hang with a status nothing expects. Every invocation is
# recorded, so the suite asserts what was asked rather than that it was asked
# nicely.
sudo() {
  mock_sudo_argv+=("$*")

  if [[ "$1" == "-n" ]]; then
    shift

    if [[ "$mock_sudo_failure" == "true" ]]; then
      printf 'sudo: a password is required\n' >&2
      return 1
    fi
  elif [[ "$mock_sudo_failure" == "true" ]]; then
    printf 'sudo: FIXTURE WOULD HAVE PROMPTED FOR A PASSWORD\n' >&2
    return 97
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

  # The authorization probe itself, which is all `sudo -n true` is.
  if [[ "$1" == "true" && $# -eq 1 ]]; then
    return 0
  fi

  if [[ "$1" != "env" || "$2" != "LC_ALL=C" || "$3" != "mokutil" ]]; then
    printf 'secure-boot fixture rejected unsupported sudo argv: %s\n' "$*" >&2
    return 96
  fi

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
  SECURE_BOOT_SUDO_AUTHORIZED=""

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

# ---------------------------------------------------------------------------
# The unattended spellings a verifier uses
# ---------------------------------------------------------------------------

assert_no_bare_sudo() {
  local invocation
  for invocation in "${mock_sudo_argv[@]}"; do
    if [[ "$invocation" != "-n "* ]]; then
      printf '%s: ran sudo without -n: %s\n' "$1" "$invocation" >&2
      exit 1
    fi
  done
}

# An unreadable certificate is not an absent one, and the two answers have to
# be distinguishable: reporting "missing" for a file sudo declined to look at
# sends someone to re-run the installer over a machine that is fine.
mock_sudo_failure="false"
mock_regular_file="/root-only/public_key.der"
mock_existing_path="/root-only/private_key.priv"
SECURE_BOOT_SUDO_AUTHORIZED=""
mock_sudo_argv=()

status=0
privileged_file_exists_unattended "$mock_regular_file" || status=$?

if ((status != 0)); then
  printf 'authorized unattended file check: expected 0, got %s\n' "$status" >&2
  exit 1
fi

status=0
privileged_file_exists_unattended "/root-only/absent.der" || status=$?

if ((status != 1)); then
  printf 'authorized unattended file check on an absent file: expected 1, got %s\n' \
    "$status" >&2
  exit 1
fi

assert_no_bare_sudo "authorized unattended file check"
printf 'PASS: an authorized unattended file check tells present from absent\n'

mock_sudo_failure="true"
SECURE_BOOT_SUDO_AUTHORIZED=""
mock_sudo_argv=()

status=0
privileged_file_exists_unattended "$mock_regular_file" || status=$?

if ((status != 2)); then
  printf 'unauthorized unattended file check: expected 2, got %s\n' "$status" >&2
  exit 1
fi

assert_no_bare_sudo "unauthorized unattended file check"
printf 'PASS: an unattended file check reports could-not-tell, not absent\n'

# probe_mok_key_unattended must reach its own verdict rather than leave the
# state at unknown, which already means "mokutil answered something this
# function cannot classify".
SECURE_BOOT_SUDO_AUTHORIZED=""
mock_sudo_argv=()

status=0
probe_mok_key_unattended /tmp/test-public-key.der || status=$?

if ((status != 2)); then
  printf 'unauthorized MOK probe: expected 2, got %s\n' "$status" >&2
  exit 1
fi

if [[ "$MOK_KEY_STATE" != "not-observed" ]]; then
  printf 'unauthorized MOK probe: expected not-observed, got %s\n' \
    "$MOK_KEY_STATE" >&2
  exit 1
fi

assert_no_bare_sudo "unauthorized MOK probe"
printf 'PASS: an unattended MOK probe reports not observed without prompting\n'

mock_sudo_failure="false"
mock_output="/tmp/test-public-key.der is already enrolled"
mock_status=0
SECURE_BOOT_SUDO_AUTHORIZED=""
mock_sudo_argv=()

probe_mok_key_unattended /tmp/test-public-key.der

if [[ "$MOK_KEY_STATE" != "enrolled" ]]; then
  printf 'authorized MOK probe: expected enrolled, got %s\n' "$MOK_KEY_STATE" >&2
  exit 1
fi

assert_no_bare_sudo "authorized MOK probe"
printf 'PASS: an authorized unattended MOK probe classifies the key\n'

# The installer keeps its interactive path. It changes system state, has
# already acquired sudo through preflight_sudo, and may legitimately ask.
SECURE_BOOT_SUDO_AUTHORIZED=""
mock_sudo_argv=()

probe_mok_key /tmp/test-public-key.der

for invocation in "${mock_sudo_argv[@]}"; do
  if [[ "$invocation" == "-n "* ]]; then
    printf 'the installer spelling acquired -n: %s\n' "$invocation" >&2
    exit 1
  fi
done

privileged_file_exists "$mock_regular_file"
privileged_path_exists "$mock_existing_path"

for invocation in "${mock_sudo_argv[@]}"; do
  if [[ "$invocation" == "-n "* ]]; then
    printf 'the installer spelling acquired -n: %s\n' "$invocation" >&2
    exit 1
  fi
done

printf 'PASS: the installer helpers still ask interactively\n'

printf 'Secure Boot helper regression tests passed.\n'
