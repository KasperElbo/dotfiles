#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
# shellcheck source=lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/parrot.sh"

theme="macchiato"
interactive="true"
dry_run="false"

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform parrot-ctf [options]

Options:
  --theme FLAVOUR    latte, frappe, macchiato, or mocha (default: macchiato)
  --dry-run          Show the installation plan without changing anything
  --non-interactive  Use defaults without prompting
  -h, --help         Show this help

This is a KVM/QEMU lab-guest profile. It does not install workstation desktop,
Fedora, KDE, ASUS, NVIDIA, VM-host, LaTeX, OCaml, or AI provisioning.
EOF
}

while (($#)); do
  case "$1" in
  --theme)
    [[ $# -ge 2 ]] || die "--theme requires a value"
    theme="$2"
    shift 2
    ;;
  --dry-run)
    dry_run="true"
    interactive="false"
    shift
    ;;
  --non-interactive)
    interactive="false"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option for parrot-ctf: $1" ;;
  esac
done

case "$theme" in
latte | frappe | macchiato | mocha) ;;
*) die "Invalid Catppuccin flavour: $theme" ;;
esac

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Parrot Security Edition CTF VM plan
-----------------------------------

Theme:                  $theme
Hypervisor:             KVM/QEMU through qemu:///system
Normal network:         libvirt default NAT
Security tools:         Existing Parrot/APT catalogue (unchanged)
Python:                 Parrot Python + venv/pipx; mise owns uv only
Host secrets:           Not forwarded or mounted
Shared folders:         Disabled unless configured manually
AI tooling:             Not installed

Steps:
  1. Require Parrot Security Edition running as a KVM/QEMU guest with the
     QEMU guest-agent and SPICE channels from the #13 host profile.
  2. Install the portable working-environment prerequisites with APT.
  3. Install qemu-guest-agent and spice-vdagent with APT and activate them.
  4. Initialize local Git/theme state and stow the headless portable profile.
  5. Apply only the narrow Parrot shims, Zsh paths, and uv mise manifest.
  6. Install uv and the pinned tmux theme, then verify the complete guest.

Excluded: Fedora/DNF/Terra, KDE/Sway, ASUS/ROG, NVIDIA, VM-host, host secret
forwarding, automatic shared folders, offensive-tool package lists, and AI.

No changes were made.
EOF
  exit 0
fi

require_parrot
vm_type="$(require_qemu_vm)"
require_guest_channels

if [[ "$interactive" == "true" ]]; then
  printf '\nParrot Security Edition CTF guest installation (%s)\n\n' "$vm_type"
  confirm "Continue with the isolated lab profile?" "y" || exit 0
fi

"$DOTFILES_ROOT/platforms/parrot-ctf/scripts/install-system.sh"
"$DOTFILES_ROOT/platforms/parrot-ctf/scripts/install-guest-integration.sh"
"$DOTFILES_ROOT/common/setup-local.sh" "$theme"
"$DOTFILES_ROOT/platforms/parrot-ctf/scripts/stow.sh"
"$DOTFILES_ROOT/common/install-mise.sh"
"$DOTFILES_ROOT/common/install-tmux-theme.sh"

theme_command="$HOME/.local/bin/theme"
[[ ! -x "$theme_command" ]] || "$theme_command" "$theme"

"$DOTFILES_ROOT/platforms/parrot-ctf/scripts/verify.sh"

cat <<'EOF'

Parrot CTF guest setup completed. Run `exec zsh -l` for the new shell.
Keep challenge state outside the dotfiles checkout and take a VM snapshot
before importing untrusted material or changing lab networking.
EOF
