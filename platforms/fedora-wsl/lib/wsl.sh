#!/usr/bin/env bash

# Fedora-on-WSL helpers. Source common/lib/common.sh before this file.

is_wsl() {
  local kernel_release_file="${KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"

  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] ||
    grep -qi microsoft "$kernel_release_file" 2>/dev/null
}

require_fedora_wsl() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id

  is_wsl || die "This installer must run inside Windows Subsystem for Linux."
  command_exists dnf || die "This installer requires Fedora and DNF."
  command_exists rpm || die "This installer requires Fedora and RPM."
  [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file"

  os_id="$(
    awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' \
      "$os_release_file"
  )"

  [[ "$os_id" == "fedora" ]] ||
    die "This WSL variant supports the official Fedora distribution only."
}

systemd_is_running() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]]
}

is_windows_path() {
  case "$1" in
  /mnt/[a-zA-Z]/* | *.exe | *.EXE) return 0 ;;
  *) return 1 ;;
  esac
}
