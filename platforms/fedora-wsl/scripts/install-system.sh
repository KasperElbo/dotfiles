#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"

require_fedora_wsl

packages=(
  bat
  bzip2
  curl
  eza
  fd-find
  fzf
  gcc
  gcc-c++
  gh
  git
  git-delta
  make
  neovim
  openssh-clients
  procps-ng
  ripgrep
  ShellCheck
  sqlite
  sqlite-devel
  starship
  stow
  tmux
  unzip
  zoxide
  zsh
  zsh-autosuggestions
  zsh-syntax-highlighting
)

info "Installing Fedora WSL command-line prerequisites"
sudo dnf install -y "${packages[@]}"

if command_exists mise || [[ -x "$HOME/.local/bin/mise" ]]; then
  info "mise is already installed"
else
  installer="$(mktemp)"
  trap 'rm -f -- "$installer"' EXIT

  info "Downloading the official mise installer"
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    https://mise.run \
    --output "$installer"

  info "Installing mise as a Linux-native user executable"
  MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh "$installer"
fi

[[ -x "$HOME/.local/bin/mise" ]] || command_exists mise ||
  die "mise installation did not produce a Linux executable"

success "Fedora WSL prerequisites installed"
