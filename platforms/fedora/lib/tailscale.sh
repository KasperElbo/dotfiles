#!/usr/bin/env bash

# Fedora Tailscale helpers shared by the profile's installer and verifier.
# Source common/lib/common.sh before this file.

# network-source: tailscale-repo
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
  # network-source: tailscale-repo
  sudo dnf config-manager addrepo --overwrite \
    --from-repofile="$TAILSCALE_REPO_URL"
}

# verify_tailscale_trust_root: whatever the fetched .repo file says becomes
# /etc/yum.repos.d/tailscale.repo verbatim, including its gpgcheck setting and
# its gpgkey URL, and ensure_tailscale_repository returns early for good
# afterwards -- so a repository shipped or later edited with gpgcheck=0 keeps
# installing root-privileged packages unchecked and nothing would say so.
# Silent when the repository is absent, because the profile is optional.
# Source common/lib/verify.sh and platforms/fedora/lib/fedora.sh first.
verify_tailscale_trust_root() {
  local repo_id repo_ids

  tailscale_repo_installed || return 0
  repo_ids="$(tailscale_repo_ids)"
  if [[ -z "$repo_ids" ]]; then
    fail "$TAILSCALE_REPO_FILE declares no repository, so which one DNF" \
      "installs Tailscale from, and whether it checks signatures, is unknown"
    return 0
  fi
  while IFS= read -r repo_id; do
    verify_repo_trust_root "$repo_id" Tailscale
  done <<<"$repo_ids"
}

# tailscale_repo_ids: every repository id the installed repo file declares,
# one per line. The id is whatever section name Tailscale's fetched .repo
# file uses ('tailscale-stable' for the stable channel), not the file's name,
# so it is read from the file rather than assumed; asking DNF about an id the
# file does not declare reads as a repository with no gpgcheck at all.
tailscale_repo_ids() {
  sed -nE 's/^[[:space:]]*\[([^]]+)\][[:space:]]*$/\1/p' \
    "$TAILSCALE_REPO_FILE" 2>/dev/null
}
