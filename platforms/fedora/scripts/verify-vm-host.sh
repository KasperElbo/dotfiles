#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

libvirt_uri="qemu:///system"
network_name="default"
pool_name="default"
smoke_test="false"
failures=0

while (($#)); do
  case "$1" in
  --smoke-test)
    smoke_test="true"
    shift
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  esac
done

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
}

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $(command -v "$command_name")"
  else
    fail "$command_name not found"
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

section "VM-host commands"
for command_name in qemu-img virsh virt-host-validate virt-install virt-manager virt-viewer; do
  check_command "$command_name"
done

if ((failures > 0)); then
  exit 1
fi

section "KVM and libvirt"

if [[ -e "${KVM_DEVICE:-/dev/kvm}" &&
  -r "${KVM_DEVICE:-/dev/kvm}" &&
  -w "${KVM_DEVICE:-/dev/kvm}" ]]; then
  pass "${KVM_DEVICE:-/dev/kvm} is available"
else
  fail "${KVM_DEVICE:-/dev/kvm} is unavailable; KVM acceleration cannot be used"
fi

if virt-host-validate qemu; then
  pass "virt-host-validate qemu"
else
  fail "virt-host-validate qemu reported a problem"
fi

if [[ "$(virsh -c "$libvirt_uri" uri 2>/dev/null || true)" == "$libvirt_uri" ]]; then
  pass "libvirt system connection: $libvirt_uri"
else
  fail "Cannot access libvirt system connection: $libvirt_uri"
fi

if virsh -c "$libvirt_uri" net-info "$network_name" 2>/dev/null |
  grep -Eiq '^[[:space:]]*Active:[[:space:]]+yes'; then
  pass "default libvirt network is active (NAT)"
else
  fail "default libvirt network is not active"
fi

if virsh -c "$libvirt_uri" net-info "$network_name" 2>/dev/null |
  grep -Eiq '^[[:space:]]*Autostart:[[:space:]]+yes'; then
  pass "default libvirt network is persistent"
else
  fail "default libvirt network is not configured for autostart"
fi

if virsh -c "$libvirt_uri" pool-info "$pool_name" 2>/dev/null |
  grep -Eiq '^[[:space:]]*State:[[:space:]]+running'; then
  pass "default libvirt storage pool is running"
else
  fail "default libvirt storage pool is not running"
fi

if virsh -c "$libvirt_uri" pool-info "$pool_name" 2>/dev/null |
  grep -Eiq '^[[:space:]]*Autostart:[[:space:]]+yes'; then
  pass "default libvirt storage pool is persistent"
else
  fail "default libvirt storage pool is not configured for autostart"
fi

if id -nG "${SUDO_USER:-${USER:-$(id -un)}}" 2>/dev/null |
  tr ' ' '\n' | grep -Fxq libvirt; then
  pass "normal user has standard libvirt group access"
else
  warning "normal user is not in the libvirt group; Fedora polkit may prompt for access"
fi

if [[ "$smoke_test" == "true" ]]; then
  section "Guest-definition smoke test"
  if virt-install \
    --connect="$libvirt_uri" \
    --name=dotfiles-vm-host-smoke \
    --memory=512 \
    --vcpus=1 \
    --disk=size=1,format=qcow2,bus=virtio \
    --network=network="$network_name",model=virtio \
    --graphics=spice \
    --boot=uefi \
    --osinfo=name=generic \
    --import \
    --dry-run \
    --print-xml >/dev/null; then
    pass "virt-install produced a UEFI/VirtIO/SPICE guest definition"
  else
    fail "virt-install guest-definition smoke test failed"
  fi
fi

printf '\n'
if ((failures > 0)); then
  printf '\033[1;31mVM-host verification failed:\033[0m %d failure(s)\n' "$failures"
  exit 1
fi

printf '\033[1;32mVM-host verification passed.\033[0m\n'
