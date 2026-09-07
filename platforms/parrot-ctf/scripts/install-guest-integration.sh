#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

require_parrot
vm_type="$(require_qemu_vm)"
require_guest_channels

info "Installing distro-owned KVM/SPICE guest integration"
sudo apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  spice-vdagent

info "Activating guest integration"
sudo systemctl enable --now qemu-guest-agent.service
sudo systemctl start spice-vdagentd.socket

state_file="$XDG_CONFIG_HOME/dotfiles/parrot-ctf.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=parrot-ctf\n'
  printf 'hypervisor=%s\n' "$vm_type"
  printf 'network=host-managed-default-nat\n'
  printf 'guest_agent=qemu-guest-agent\n'
  printf 'display=spice\n'
  printf 'shared_folders=manual\n'
  printf 'host_secrets=not-shared\n'
  printf 'security_tools=parrot-apt-owned\n'
} | atomic_write_file "$state_file"

success "Parrot guest integration installed"
