#!/usr/bin/env bash

# Secure Boot helpers. Source common/lib/common.sh before this file.

MOK_KEY_STATE="unknown"
MOK_KEY_STATUS=0
MOK_KEY_OUTPUT=""
SECURE_BOOT_SUDO_AUTHORIZED=""

# The privileged helpers below come in two spellings, and the caller picks by
# what it is. An installer changes system state, has already acquired sudo
# through preflight_sudo, and may legitimately ask for a password. A verifier
# is the thing you run from a script, a timer, or a session with no terminal to
# answer on, so for it a password prompt is a hang rather than a question. The
# `_unattended` variants never prompt and report "could not tell" as its own
# answer, separate from "absent".

# secure_boot_privileged_read_available: whether sudo answers without asking
# for a password. Cached for the process, so a verifier pays for the probe once
# rather than once per certificate it looks at.
secure_boot_privileged_read_available() {
  if [[ -z "$SECURE_BOOT_SUDO_AUTHORIZED" ]]; then
    if sudo -n true 2>/dev/null; then
      SECURE_BOOT_SUDO_AUTHORIZED="true"
    else
      SECURE_BOOT_SUDO_AUTHORIZED="false"
    fi
  fi

  [[ "$SECURE_BOOT_SUDO_AUTHORIZED" == "true" ]]
}

privileged_file_exists() {
  sudo test -f "$1"
}

privileged_path_exists() {
  sudo test -e "$1"
}

# privileged_file_exists_unattended <path>: 0 present, 1 absent, 2 could not
# tell.
#
# An unprivileged stat cannot tell an absent file from one inside a directory
# this user may not search, so a negative answer is only conclusive when sudo
# could be asked.
privileged_file_exists_unattended() {
  [[ ! -f "$1" ]] || return 0
  secure_boot_privileged_read_available || return 2
  sudo -n test -f "$1" 2>/dev/null || return 1
}

secure_boot_state() {
  local output
  local efivars_root="${EFI_VARS_ROOT:-/sys/firmware/efi/efivars}"
  local secure_boot_variables
  local value

  if command_exists mokutil; then
    output="$(LC_ALL=C mokutil --sb-state 2>&1 || true)"

    if grep -qi 'SecureBoot enabled' <<<"$output"; then
      printf 'enabled\n'
      return
    fi

    if grep -qi 'SecureBoot disabled' <<<"$output"; then
      printf 'disabled\n'
      return
    fi
  fi

  secure_boot_variables=("$efivars_root"/SecureBoot-*)

  if [[ -r "${secure_boot_variables[0]}" ]]; then
    value="$(
      od -An -t u1 -j 4 -N 1 "${secure_boot_variables[0]}" 2>/dev/null |
        tr -d '[:space:]'
    )"

    case "$value" in
    1)
      printf 'enabled\n'
      return
      ;;
    0)
      printf 'disabled\n'
      return
      ;;
    esac
  fi

  printf 'unknown\n'
}

# _probe_mok_key <certificate> <privilege-prefix...>
#
# The classification below is the same question however the command is
# privileged, so the two entry points differ only in the prefix they pass and
# in what they do when sudo will not answer.
_probe_mok_key() {
  local certificate="$1"
  shift

  MOK_KEY_STATE="unknown"
  MOK_KEY_STATUS=0
  MOK_KEY_OUTPUT=""

  if MOK_KEY_OUTPUT="$(
    "$@" env LC_ALL=C mokutil --test-key "$certificate" 2>&1
  )"; then
    MOK_KEY_STATUS=0
  else
    MOK_KEY_STATUS=$?
  fi

  case "$MOK_KEY_OUTPUT" in
  *" is blocked"*)
    MOK_KEY_STATE="blocked"
    ;;
  *" is already in the enrollment request"*)
    MOK_KEY_STATE="pending"
    ;;
  *" is not enrolled"*)
    MOK_KEY_STATE="not-enrolled"
    ;;
  *" is already enrolled"* | \
    *" is already in db"* | \
    *" is already in the built-in trusted keyring"*)
    MOK_KEY_STATE="enrolled"
    ;;
  esac

  if [[ "$MOK_KEY_STATE" == "unknown" && "$MOK_KEY_STATUS" -eq 0 ]]; then
    MOK_KEY_STATE="enrolled"
  fi
}

probe_mok_key() {
  _probe_mok_key "$1" sudo
}

# probe_mok_key_unattended <certificate>: 2 when sudo would have had to ask,
# otherwise whatever _probe_mok_key determined.
#
# MOK_KEY_STATE is set to not-observed rather than left at unknown, because
# unknown already means "mokutil answered something this function cannot
# classify", which is a different report to make.
probe_mok_key_unattended() {
  if ! secure_boot_privileged_read_available; then
    MOK_KEY_STATE="not-observed"
    MOK_KEY_STATUS=0
    MOK_KEY_OUTPUT=""
    return 2
  fi

  _probe_mok_key "$1" sudo -n

  # A timestamp that expired between the probe above and this call leaves
  # mokutil unrun and sudo's refusal in MOK_KEY_OUTPUT. Ask sudo again rather
  # than matching that message, which is localized and would be an assertion
  # about sudo's wording instead of about authorization.
  if [[ "$MOK_KEY_STATE" == "unknown" && "$MOK_KEY_STATUS" -ne 0 ]]; then
    SECURE_BOOT_SUDO_AUTHORIZED=""

    if ! secure_boot_privileged_read_available; then
      MOK_KEY_STATE="not-observed"
      MOK_KEY_OUTPUT=""
      return 2
    fi
  fi
}
