#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

command_exists dnf || die "This installer currently supports Fedora/DNF systems only."

packages=(
  blueman
  brightnessctl
  cliphist
  dex-autostart
  fuzzel
  grim
  jq
  libnotify
  lxqt-policykit
  mako
  nm-connection-editor
  pavucontrol
  playerctl
  slurp
  sway
  swaybg
  swayidle
  swaylock
  sway-systemd
  swappy
  waybar
  wireplumber
  xdg-desktop-portal-gtk
  xdg-desktop-portal-wlr
)

info "Installing the optional Sway session"
sudo dnf install -y "${packages[@]}"

info "Installing the dotfiles Sway login session"
sudo install -Dm755 \
  "$DOTFILES_ROOT/platforms/fedora/assets/dotfiles-sway" \
  /usr/local/bin/dotfiles-sway
sudo install -Dm644 \
  "$DOTFILES_ROOT/platforms/fedora/assets/dotfiles-sway.desktop" \
  /usr/share/wayland-sessions/dotfiles-sway.desktop

success "Sway session packages installed"
