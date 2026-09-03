#!/usr/bin/env bash

# Secure Boot helpers. Source scripts/lib/common.sh before this file.

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
