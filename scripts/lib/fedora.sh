#!/usr/bin/env bash

# Fedora-specific helpers. Source scripts/lib/common.sh before this file.

require_fedora() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id

  command_exists dnf || die "This installer requires Fedora and DNF."
  command_exists rpm || die "This installer requires Fedora and RPM."
  [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file"

  os_id="$(
    awk -F= '$1 == "ID" { gsub(/\"/, "", $2); print $2 }' \
      "$os_release_file"
  )"

  [[ "$os_id" == "fedora" ]] || die "This installer supports Fedora only."
}

ensure_terra_repository() {
  if rpm -q terra-release >/dev/null 2>&1; then
    info "Terra repository already installed"
    return
  fi

  info "Enabling the Terra repository"
  sudo dnf install -y \
    --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release
}

ensure_rpm_fusion_repositories() {
  if rpm -q \
    rpmfusion-free-release \
    rpmfusion-nonfree-release >/dev/null 2>&1; then
    info "RPM Fusion repositories already installed"
    return
  fi

  local fedora_version
  fedora_version="$(rpm -E %fedora)"

  info "Enabling the RPM Fusion repositories"
  sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"
}
