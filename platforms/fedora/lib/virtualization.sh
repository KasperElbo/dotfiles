#!/usr/bin/env bash

# Virtualization helpers shared by Fedora guest installation and verification.
# Source common/lib/common.sh before this file.

detect_vm_type() {
  require_command systemd-detect-virt

  local vm_type
  vm_type="$(systemd-detect-virt --vm 2>/dev/null || true)"
  printf '%s\n' "${vm_type:-none}"
}

require_vm_type() {
  local vm_type
  vm_type="$(detect_vm_type)"

  if [[ "$vm_type" == "none" ]]; then
    die "The VM-guest profile must be run inside a detected virtual machine."
  fi

  printf '%s\n' "$vm_type"
}

require_qemu_vm_type() {
  local vm_type
  vm_type="$(require_vm_type)"

  case "$vm_type" in
  kvm | qemu)
    printf '%s\n' "$vm_type"
    ;;
  *)
    die "The VM-guest profile currently supports KVM/QEMU guests; detected $vm_type."
    ;;
  esac
}
