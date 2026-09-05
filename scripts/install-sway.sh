#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

command_exists dnf || die "This installer currently supports Fedora/DNF systems only."

packages=(
  blueman
  brightnessctl
  cliphist
  fuzzel
  grim
  jq
  libnotify
  lxqt-policykit
  mako
  NetworkManager-connection-editor
  pavucontrol
  playerctl
  slurp
  sway
  swaybg
  swayidle
  swaylock
  swappy
  waybar
  wireplumber
  xdg-desktop-portal-gtk
  xdg-desktop-portal-wlr
)

info "Installing the optional Sway session"
sudo dnf install -y "${packages[@]}"

success "Sway session packages installed"
