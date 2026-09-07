#!/usr/bin/env bash

# Parrot-specific helpers. Source common/lib/common.sh before this file.

require_parrot() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id

  command_exists apt-get || die "This installer requires Parrot and APT."
  command_exists dpkg-query || die "This installer requires Parrot and dpkg."
  [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file"

  os_id="$(
    awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' \
      "$os_release_file" | head -n 1
  )"

  [[ "$os_id" == "parrot" ]] ||
    die "This profile supports Parrot Security Edition only."
}

require_qemu_vm() {
  local vm_type

  command_exists systemd-detect-virt ||
    die "systemd-detect-virt is required to validate the CTF guest."

  vm_type="$(systemd-detect-virt --vm 2>/dev/null || true)"
  case "$vm_type" in
  kvm | qemu)
    printf '%s\n' "$vm_type"
    ;;
  none | "")
    die "The Parrot CTF profile must run inside a detected virtual machine."
    ;;
  *)
    die "The Parrot CTF profile supports KVM/QEMU guests; detected $vm_type."
    ;;
  esac
}

require_guest_channels() {
  local qemu_channel="${QEMU_AGENT_CHANNEL:-/dev/virtio-ports/org.qemu.guest_agent.0}"
  local spice_channel="${SPICE_AGENT_CHANNEL:-/dev/virtio-ports/com.redhat.spice.0}"

  [[ -e "$qemu_channel" ]] ||
    die "QEMU guest-agent channel missing: $qemu_channel"
  [[ -e "$spice_channel" ]] ||
    die "SPICE agent channel missing: $spice_channel"
}
