#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/virtualization.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/virtualization.sh"

qemu_agent_channel="${QEMU_AGENT_CHANNEL:-/dev/virtio-ports/org.qemu.guest_agent.0}"
spice_agent_channel="${SPICE_AGENT_CHANNEL:-/dev/virtio-ports/com.redhat.spice.0}"
legacy_clipboard_bridge_unit="dotfiles-spice-wayland-clipboard.service"
legacy_clipboard_bridge_path="$XDG_CONFIG_HOME/systemd/user/$legacy_clipboard_bridge_unit"
failures=0
warnings=0

[[ $# -eq 0 ]] || {
  printf 'Unknown option: %s\n' "$1" >&2
  exit 2
}

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

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

if systemctl is-active --quiet qemu-guest-agent.service; then
  pass "qemu-guest-agent.service is active"
else
  fail "qemu-guest-agent.service is not active"
fi

if systemctl is-active --quiet spice-vdagentd.socket; then
  pass "spice-vdagentd.socket is active"
else
  fail "spice-vdagentd.socket is not active"
fi

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

printf '\n'
if ((failures > 0)); then
  printf '\033[1;31mVM-guest verification failed:\033[0m %d failure(s), %d warning(s)\n' \
    "$failures" "$warnings"
  exit 1
fi

printf '\033[1;32mVM-guest verification passed.\033[0m %d warning(s)\n' \
  "$warnings"
