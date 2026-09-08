#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

require_apple_silicon_macos
require_native_homebrew
activate_homebrew_path

info "Installing the optional Tailscale profile (Standalone macOS app)"
"$(homebrew_path)" install --cask tailscale-app

state_file="$XDG_CONFIG_HOME/dotfiles/macos-tailscale.conf"
ensure_dir "$(dirname "$state_file")"
atomic_write_file "$state_file" <<'EOF'
profile=tailscale
variant=standalone-app
EOF

info "Opening Tailscale so macOS can request its Network Extension permission"
open -a Tailscale || warn "Open Tailscale manually from /Applications"

success "Optional Tailscale profile installed"

cat <<'EOF'

Tailscale is installed but not connected yet. Finish setup interactively:

  1. Approve the Network Extension permission prompt (or grant it later in
     System Settings -> General -> Login Items & Extensions -> Network
     Extensions).
  2. Open the Tailscale menu-bar icon and sign in to your tailnet.

Optional: enable the command-line tool from the Tailscale app's Settings ->
CLI section ("Install Now"; installs to /usr/local/bin/tailscale and asks
for your admin password once). Until then, use the app bundle path:

    /Applications/Tailscale.app/Contents/MacOS/Tailscale status

No account/tailnet policy is set by this installer. See README.md,
"Optional Tailscale networking profile" for common follow-up commands.

EOF
