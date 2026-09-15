#!/usr/bin/env bash

# Fedora Tailscale helpers shared by the profile's installer and verifier.
# Source common/lib/common.sh before this file.

# shellcheck disable=SC2034 # consumed by install-tailscale.sh/verify-tailscale.sh
TAILSCALE_REPO_URL="${TAILSCALE_REPO_URL:-https://pkgs.tailscale.com/stable/fedora/tailscale.repo}"
# shellcheck disable=SC2034 # consumed by install-tailscale.sh/verify-tailscale.sh
TAILSCALE_REPO_FILE="${TAILSCALE_REPO_FILE:-/etc/yum.repos.d/tailscale.repo}"

# tailscale_repo_installed: true if the Tailscale DNF repo file is already
# present. A plain (non-sudo) file test is enough: DNF repo files under
# /etc/yum.repos.d are world-readable, and this must stay sudo-free so
# --dry-run never shells out to sudo.
tailscale_repo_installed() {
  [[ -f "$TAILSCALE_REPO_FILE" ]]
}

# ensure_tailscale_repository: adds Tailscale's own Fedora/DNF repository
# (https://tailscale.com/download/linux/fedora) via dnf5's config-manager
# plugin, the same command Tailscale's own install script runs for
# dnf5-based Fedora releases. Safe to rerun: a machine that already has the
# repo file is left untouched, and 'addrepo --overwrite' is itself
# idempotent if run again.
ensure_tailscale_repository() {
  if tailscale_repo_installed; then
    info "Tailscale repository already installed"
    return
  fi

  if ! rpm -q dnf5-plugins >/dev/null 2>&1; then
    info "Installing dnf5-plugins for 'dnf config-manager'"
    sudo dnf install -y dnf5-plugins
  fi

  info "Adding the Tailscale package repository ($TAILSCALE_REPO_URL)"
  sudo dnf config-manager addrepo --overwrite \
    --from-repofile="$TAILSCALE_REPO_URL"
}
