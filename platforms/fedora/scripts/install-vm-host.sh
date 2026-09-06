#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

libvirt_uri="qemu:///system"
libvirt_network="default"
libvirt_pool="default"
libvirt_image_dir="/var/lib/libvirt/images"
target_user="${SUDO_USER:-${USER:-$(id -un)}}"
dry_run="false"
validate_only="false"
smoke_test="false"

vm_host_packages=(
  edk2-ovmf
  libvirt-client
  libvirt-daemon-config-network
  libvirt-daemon-driver-qemu
  qemu-img
  qemu-kvm
  spice-gtk
  spice-server
  swtpm
  swtpm-tools
  virt-install
  virt-manager
  virt-viewer
)

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-vm-host.sh [options]

Install the optional Fedora KVM/QEMU + libvirt VM-host profile.

Options:
  --dry-run          Show the VM-host plan without changing anything
  --validate         Validate an existing VM-host installation only
  --smoke-test       Render a representative guest definition without creating it
  -h, --help         Show this help

The profile uses qemu:///system, libvirt's default NAT network and storage pool,
qcow2 disks, UEFI/OVMF firmware, VirtIO devices, and SPICE guest consoles.
It does not create a bridge or change Secure Boot, SELinux, or firewalld.
EOF
}

while (($#)); do
  case "$1" in
  --dry-run)
    dry_run="true"
    shift
    ;;
  --validate)
    validate_only="true"
    shift
    ;;
  --smoke-test)
    smoke_test="true"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
done

if [[ "$dry_run" == "true" && "$validate_only" == "true" ]]; then
  die "--dry-run and --validate cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  if [[ "$smoke_test" == "true" ]]; then
    exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh" --smoke-test
  fi
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Fedora VM-host installation plan
--------------------------------

Backend:                KVM/QEMU + libvirt
Primary GUI:            virt-manager
CLI/automation:         virt-install, virsh
Guest console:          virt-viewer with SPICE
libvirt connection:     $libvirt_uri
libvirt network:        $libvirt_network (NAT, no bridge)
libvirt storage pool:   $libvirt_pool ($libvirt_image_dir)
Guest disks:            qcow2 with VirtIO devices
Guest firmware:         UEFI/OVMF with optional TPM support
Guest agents:           installed inside guests with --vm-guest
Host access:            standard Fedora libvirt/polkit policy and libvirt group

Packages:
$(printf '  %s\n' "${vm_host_packages[@]}")

Steps:
  1. Install the Fedora virtualization packages listed above.
  2. Activate libvirt's system daemon/socket units.
  3. Ensure the default libvirt NAT network and storage pool are active and persistent.
  4. Preserve Secure Boot, SELinux, and firewalld settings.
  5. Validate KVM acceleration, qemu:///system access, networking, storage, and guest XML.
  6. Record the host conventions in \$XDG_CONFIG_HOME/dotfiles/vm-host.conf.

No changes were made.

EOF
  exit 0
fi

require_fedora

if [[ "$smoke_test" == "true" ]]; then
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh" --smoke-test
fi

info "Installing Fedora VM-host packages"
sudo dnf install -y "${vm_host_packages[@]}"

if systemctl cat libvirtd.service >/dev/null 2>&1; then
  info "Activating the libvirt system service"
  sudo systemctl enable --now libvirtd.service
else
  info "Activating modular libvirt daemon sockets"
  for unit in virtqemud.socket virtnetworkd.socket virtstoraged.socket; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      sudo systemctl enable --now "$unit"
    fi
  done
fi

if getent group libvirt >/dev/null 2>&1; then
  if ! id -nG "$target_user" | tr ' ' '\n' | grep -Fxq libvirt; then
    info "Adding $target_user to the standard libvirt group"
    sudo usermod -aG libvirt "$target_user"
    warn "Log out and back in before using qemu:///system as $target_user"
  else
    info "$target_user already has standard libvirt access"
  fi
else
  info "Using Fedora's upstream libvirt/polkit policy for $target_user"
fi

if ! virsh -c "$libvirt_uri" net-info "$libvirt_network" >/dev/null 2>&1; then
  die "libvirt network '$libvirt_network' is unavailable; no network was created"
fi

if ! virsh -c "$libvirt_uri" net-info "$libvirt_network" |
  grep -Ei '^[[:space:]]*Active:[[:space:]]+yes' >/dev/null; then
  info "Starting libvirt's default NAT network"
  sudo virsh -c "$libvirt_uri" net-start "$libvirt_network"
fi
sudo virsh -c "$libvirt_uri" net-autostart "$libvirt_network"

if ! virsh -c "$libvirt_uri" pool-info "$libvirt_pool" >/dev/null 2>&1; then
  info "Creating libvirt's default storage pool"
  sudo install -d -m 0755 "$libvirt_image_dir"
  if command_exists restorecon; then
    sudo restorecon -RF "$libvirt_image_dir"
  fi
  sudo virsh -c "$libvirt_uri" pool-define-as \
    "$libvirt_pool" dir --target "$libvirt_image_dir"
fi

if ! virsh -c "$libvirt_uri" pool-info "$libvirt_pool" |
  grep -Ei '^[[:space:]]*State:[[:space:]]+running' >/dev/null; then
  info "Starting libvirt's default storage pool"
  sudo virsh -c "$libvirt_uri" pool-start "$libvirt_pool"
fi
sudo virsh -c "$libvirt_uri" pool-autostart "$libvirt_pool"

state_file="$XDG_CONFIG_HOME/dotfiles/vm-host.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=vm-host\n'
  printf 'backend=kvm-qemu-libvirt\n'
  printf 'libvirt_uri=%s\n' "$libvirt_uri"
  printf 'network=%s\n' "$libvirt_network"
  printf 'network_mode=nat\n'
  printf 'storage_pool=%s\n' "$libvirt_pool"
  printf 'storage_path=%s\n' "$libvirt_image_dir"
  printf 'disk_format=qcow2\n'
  printf 'firmware=uefi-ovmf\n'
  printf 'display=spice\n'
  printf 'device_model=virtio\n'
  printf 'guest_agent=qemu-guest-agent\n'
  printf 'user=%s\n' "$target_user"
} | atomic_write_file "$state_file"

info "Validating the Fedora VM-host profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh"; then
  success "Fedora VM-host profile installed"
else
  warn "VM-host packages were installed, but validation reported problems"
  exit 1
fi
