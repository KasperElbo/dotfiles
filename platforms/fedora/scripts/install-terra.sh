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

# mise's own upstream install docs point Fedora users at a separate
# jdxcode/mise COPR repo. If that repo is also enabled, its mise package
# conflicts with the Terra-provided mise-zsh-completion package (which
# requires an exact matching mise version), and dnf silently skips
# installing/upgrading mise rather than choosing between the two repos.
# Exclude that repo for this transaction so Terra's mise always wins;
# --disablerepo is a safe no-op when the repo is not enabled.
sudo dnf install -y \
  --disablerepo="copr:copr.fedorainfracloud.org:jdxcode:mise" \
  "${packages[@]}"

success "Terra packages installed"
