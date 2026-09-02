#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

command_exists dnf || die "Terra setup currently supports Fedora/DNF systems only."

if ! rpm -q terra-release >/dev/null 2>&1; then
  info "Enabling the Terra repository"

  sudo dnf install -y \
    --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release
else
  info "Terra repository already installed"
fi

packages=(
  ghostty
  mise
  starship
)

info "Installing Terra packages"
sudo dnf install -y "${packages[@]}"

success "Terra packages installed"
