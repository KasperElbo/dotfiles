#!/usr/bin/env bash

# Secure Boot helpers. Source scripts/lib/common.sh before this file.

MOK_KEY_STATE="unknown"
MOK_KEY_STATUS=0
MOK_KEY_OUTPUT=""

privileged_file_exists() {
  sudo test -f "$1"
}

privileged_path_exists() {
  sudo test -e "$1"
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

probe_mok_key() {
  local certificate="$1"

  MOK_KEY_STATE="unknown"
  MOK_KEY_STATUS=0
  MOK_KEY_OUTPUT=""

  if MOK_KEY_OUTPUT="$(
    sudo env LC_ALL=C mokutil --test-key "$certificate" 2>&1
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
