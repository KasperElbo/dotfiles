#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command git

version="v0.2.7"
repo="https://github.com/catppuccin/kde.git"
workdir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/catppuccin-kde"

rm -rf "$workdir"
ensure_dir "$(dirname "$workdir")"

info "Downloading Catppuccin KDE $version"

git clone \
  --branch "$version" \
  --depth 1 \
  "$repo" \
  "$workdir"

cd "$workdir"

# Catppuccin KDE installer choices:
#
# flavour:
#   1 = Latte
#   2 = Frappé
#   3 = Macchiato
#   4 = Mocha
#
# accent:
#   4 = Mauve
#
# window decoration:
#   2 = Classic
#
# "auto" = non-interactive installation.
#
# Cursor installation remains enabled.

for flavour in 1 2 3 4; do
  info "Installing Catppuccin KDE flavour $flavour"
  ./install.sh "$flavour" 4 2 auto
done

success "All Catppuccin KDE flavours installed"
