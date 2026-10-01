#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

require_apple_silicon_macos
require_native_homebrew
activate_homebrew_path

# A Brewfile of its own, so the tap and the cask stay where the network-source
# linter reads Homebrew trust roots, and out of the baseline every Mac runs.
info "Installing the AeroSpace tiling window manager"
"$(homebrew_path)" bundle --file="$DOTFILES_ROOT/platforms/macos/aerospace/Brewfile"

# Stow has already linked the tracked configuration, so the first launch reads
# it. macOS asks for Accessibility access here.
info "Opening AeroSpace so macOS can request Accessibility access"
open -a AeroSpace || warn 'Open AeroSpace manually from /Applications'

success "AeroSpace installed"
