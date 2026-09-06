#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

require_fedora
ensure_terra_repository

packages=(
  ghostty
  mise
  starship
)

info "Installing Terra packages"
sudo dnf install -y "${packages[@]}"

success "Terra packages installed"
