#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/virtualization.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/virtualization.sh"

qemu_agent_channel="${QEMU_AGENT_CHANNEL:-/dev/virtio-ports/org.qemu.guest_agent.0}"
spice_agent_channel="${SPICE_AGENT_CHANNEL:-/dev/virtio-ports/com.redhat.spice.0}"
dry_run="false"
validate_only="false"
preflight_only="false"

vm_guest_packages=(
  qemu-guest-agent
  spice-vdagent
  xclip
)

clipboard_bridge_unit="dotfiles-spice-wayland-clipboard.service"

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-vm-guest.sh [options]

Install the minimal Fedora KVM/QEMU guest-integration profile.

Options:
  --dry-run          Show the VM-guest plan without changing anything
  --validate         Validate an existing VM-guest installation only
  --preflight        Validate the guest and host channels without changes
  -h, --help         Show this help

The profile is explicit: it never auto-selects itself and refuses to run on
bare metal or a non-QEMU hypervisor. It adds only the QEMU guest agent and
SPICE desktop agent; the normal Fedora and portable bootstrap remain shared.
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
  --preflight)
    preflight_only="true"
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

if [[ "$dry_run" == "true" && "$preflight_only" == "true" ]]; then
  die "--dry-run and --preflight cannot be combined"
fi

if [[ "$validate_only" == "true" && "$preflight_only" == "true" ]]; then
  die "--validate and --preflight cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-guest.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Fedora VM-guest installation plan
---------------------------------

Reference hypervisor:   KVM/QEMU through libvirt
Guest network:          Existing guest network (default host profile uses NAT)
Guest devices:          Existing VirtIO disk, network, and serial channels
Desktop integration:    SPICE clipboard, dynamic display, and pointer support
Power management:       No laptop power-profile or battery changes
Shared folders:         No host path is mounted implicitly

Packages:
$(printf '  %s\n' "${vm_guest_packages[@]}")

Steps:
  1. Verify Fedora and explicitly detect a KVM/QEMU virtual machine.
  2. Require the QEMU and SPICE virtio-serial channels supplied by the host.
  3. Install qemu-guest-agent, spice-vdagent, and the small X11 clipboard helper.
  4. Activate the packaged agents and a VM-only Wayland-to-SPICE text clipboard bridge.
  5. Preserve NetworkManager, display layout, power settings, and shared folders.
  6. Record the guest profile in \$XDG_CONFIG_HOME/dotfiles/vm-guest.conf.
  7. Validate guest agents, channels, and the existing default route.

No changes were made.

EOF
  exit 0
fi

require_fedora
vm_type="$(require_qemu_vm_type)"

[[ -e "$qemu_agent_channel" ]] ||
  die "QEMU guest-agent channel missing: $qemu_agent_channel. Add org.qemu.guest_agent.0 to the VM."
[[ -e "$spice_agent_channel" ]] ||
  die "SPICE agent channel missing: $spice_agent_channel. Add com.redhat.spice.0 to the VM."

info "Detected $vm_type virtual machine"

if [[ "$preflight_only" == "true" ]]; then
  success "Fedora VM-guest preflight passed"
  exit 0
fi

info "Installing Fedora VM-guest packages"
sudo dnf install -y "${vm_guest_packages[@]}"

clipboard_bridge_path="$XDG_CONFIG_HOME/systemd/user/$clipboard_bridge_unit"
ensure_dir "$(dirname "$clipboard_bridge_path")"
cat <<'EOF' | atomic_write_file "$clipboard_bridge_path"
[Unit]
Description=Bridge the Wayland text clipboard to SPICE through XWayland
PartOf=graphical-session.target
After=graphical-session.target spice-vdagent.service
ConditionEnvironment=XDG_SESSION_TYPE=wayland

[Service]
Type=simple
ExecStart=/usr/bin/wl-paste --type text --watch /usr/bin/sh -c 'case "$$CLIPBOARD_STATE" in data) exec /usr/bin/xclip -selection clipboard ;; *) exec /usr/bin/xclip -selection clipboard </dev/null ;; esac'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

info "Activating VM-guest services"
sudo systemctl enable --now qemu-guest-agent.service
# Fedora activates this static socket from the SPICE virtio-port udev rule.
sudo systemctl start spice-vdagentd.socket
systemctl --user daemon-reload
systemctl --user enable --now "$clipboard_bridge_unit"

state_file="$XDG_CONFIG_HOME/dotfiles/vm-guest.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=vm-guest\n'
  printf 'hypervisor=%s\n' "$vm_type"
  printf 'guest_agent=qemu-guest-agent\n'
  printf 'desktop_agent=spice-vdagent\n'
  printf 'clipboard_bridge=wayland-to-x11\n'
  printf 'display=spice\n'
  printf 'network=host-managed\n'
  printf 'shared_folders=manual\n'
} | atomic_write_file "$state_file"

info "Validating the Fedora VM-guest profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-guest.sh"; then
  success "Fedora VM-guest profile installed"
else
  warn "VM-guest packages were installed, but validation reported problems"
  exit 1
fi
