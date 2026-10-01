#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

require_apple_silicon_macos
require_native_homebrew
activate_homebrew_path

# AeroSpace is not in homebrew/cask; upstream publishes it through its own tap.
info "Installing the AeroSpace tiling window manager"
# network-source: homebrew-tap-nikitabobko
"$(homebrew_path)" install --cask nikitabobko/tap/aerospace

# Stow has already linked the tracked configuration, so the first launch reads
# it. macOS asks for Accessibility access here.
info "Opening AeroSpace so macOS can request Accessibility access"
open -a AeroSpace || warn 'Open AeroSpace manually from /Applications'

success "AeroSpace installed"
