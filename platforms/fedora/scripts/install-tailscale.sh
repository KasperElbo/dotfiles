#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/tailscale.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/tailscale.sh"

dry_run="false"
validate_only="false"

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-tailscale.sh [options]

Install the optional Tailscale networking profile: the tailscale CLI and
the tailscaled service, from Tailscale's own supported Fedora/DNF package
repository.

Options:
  --dry-run          Show the Tailscale plan without changing anything
  --validate         Validate an existing Tailscale installation only
  -h, --help         Show this help

Installs tailscale from https://pkgs.tailscale.com/stable/fedora/, the same
repository Tailscale's own install script uses for Fedora, rather than a
standalone downloaded binary. Enables and starts tailscaled. Never runs
'tailscale up', never embeds an auth key or OAuth client secret, and never
sets tailnet-specific policy (ACLs, exit nodes, subnet routes, Tailscale
SSH) -- authenticating this machine remains a manual, interactive step. See
README.md, "Optional Tailscale networking profile" for follow-up commands.
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
  exec "$DOTFILES_ROOT/platforms/fedora/scripts/verify-tailscale.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  if tailscale_repo_installed; then
    repo_plan="already installed at $TAILSCALE_REPO_FILE; left unchanged"
  else
    repo_plan="add from $TAILSCALE_REPO_URL"
  fi

  cat <<EOF

Fedora Tailscale installation plan
-----------------------------------

Package repository:    pkgs.tailscale.com (Tailscale's own Fedora repo)
Repository:             $repo_plan
Package:                tailscale (tailscale CLI + tailscaled service)
Service:                tailscaled, enabled and started
Authentication:         not automated; 'tailscale up' is never run here
Embedded credentials:   none (no auth key, no OAuth secret, no tailnet policy)

Steps:
  1. Ensure the Tailscale DNF repository is present (add it only if missing).
  2. Install the tailscale package.
  3. Enable and start the tailscaled service.
  4. Record the profile in \$XDG_CONFIG_HOME/dotfiles/tailscale.conf.
  5. Validate the CLI, service, and reachable-but-unauthenticated state.

Does not run 'tailscale up', does not weaken firewalld or SELinux, and does
not enable Tailscale SSH, exit-node use, subnet routing, or MagicDNS.

No changes were made.

EOF
  exit 0
fi

require_fedora

ensure_tailscale_repository

info "Installing the Tailscale package"
sudo dnf install -y tailscale

info "Enabling and starting tailscaled"
sudo systemctl enable --now tailscaled

state_file="$XDG_CONFIG_HOME/dotfiles/tailscale.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=tailscale\n'
  printf 'repo=pkgs.tailscale.com\n'
  printf 'service=tailscaled\n'
} | atomic_write_file "$state_file"

info "Validating the Fedora Tailscale profile"
if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-tailscale.sh"; then
  success "Fedora Tailscale profile installed"
else
  warn "Tailscale was installed, but validation reported problems"
  exit 1
fi

cat <<'EOF'

Tailscale is installed but not connected to a tailnet yet. To authenticate
this machine, run:

    sudo tailscale up

This opens an interactive login link; it does not carry any account/tailnet
policy of its own. See README.md, "Optional Tailscale networking profile"
for common follow-up commands (status, IPs, logout) and what this profile
intentionally leaves to you (ACLs, exit nodes, subnet routes, Tailscale SSH,
--accept-routes/--accept-dns).

EOF
