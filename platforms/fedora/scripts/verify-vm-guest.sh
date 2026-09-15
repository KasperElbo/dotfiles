#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../lib/virtualization.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/virtualization.sh"

qemu_agent_channel="${QEMU_AGENT_CHANNEL:-/dev/virtio-ports/org.qemu.guest_agent.0}"
spice_agent_channel="${SPICE_AGENT_CHANNEL:-/dev/virtio-ports/com.redhat.spice.0}"
legacy_clipboard_bridge_unit="dotfiles-spice-wayland-clipboard.service"
legacy_clipboard_bridge_path="$XDG_CONFIG_HOME/systemd/user/$legacy_clipboard_bridge_unit"

[[ $# -eq 0 ]] || {
  printf 'Unknown option: %s\n' "$1" >&2
  exit 2
}

verify_reset

section "VM guest"

vm_type="$(detect_vm_type)"
case "$vm_type" in
kvm | qemu)
  pass "Virtual machine detected: $vm_type"
  ;;
none)
  fail "No virtual machine detected"
  ;;
*)
  fail "Unsupported VM-guest hypervisor detected: $vm_type"
  ;;
esac

for package_name in qemu-guest-agent spice-vdagent xclip; do
  if rpm -q "$package_name" >/dev/null 2>&1; then
    pass "Fedora package installed: $package_name"
  else
    fail "Fedora package missing: $package_name"
  fi
done

if [[ -e "$qemu_agent_channel" ]]; then
  pass "QEMU guest-agent channel: $qemu_agent_channel"
else
  fail "QEMU guest-agent channel missing: $qemu_agent_channel"
fi

if [[ -e "$spice_agent_channel" ]]; then
  pass "SPICE agent channel: $spice_agent_channel"
else
  fail "SPICE agent channel missing: $spice_agent_channel"
fi

# Device- and socket-activated units: is-active is the meaningful state (see
# check_system_service_enabled_and_active in common/lib/verify.sh).
check_system_service_active qemu-guest-agent.service
check_system_service_active spice-vdagentd.socket

if systemctl --user is-active --quiet spice-vdagent.service 2>/dev/null; then
  pass "Plasma SPICE session agent is active"
else
  warning "SPICE session agent is not active; log in to Plasma before checking clipboard and dynamic resize"
fi

if [[ -e "$legacy_clipboard_bridge_path" ]]; then
  if systemctl --user is-active --quiet "$legacy_clipboard_bridge_unit" 2>/dev/null; then
    fail "Rejected clipboard bridge is active; stop $legacy_clipboard_bridge_unit immediately"
  else
    warning "Rejected clipboard bridge remains installed; rerun the VM-guest installer to remove it"
  fi
fi

if ip route show default 2>/dev/null | grep -q .; then
  pass "Guest has a default network route"
else
  fail "Guest has no default network route"
fi

finish_verification "VM-guest verification"
