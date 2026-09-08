#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

command_exists dnf || die "This installer currently supports Fedora/DNF systems only."

packages=(
  bat
  curl
  eza
  fd-find
  fzf
  gh
  git
  git-delta
  neovim
  ripgrep
  ShellCheck
  shadow-utils
  sqlite
  sqlite-devel
  stow
  tmux
  wl-clipboard
  xdg-utils
  zoxide
  zsh
  zsh-autosuggestions
  zsh-syntax-highlighting
)

info "Installing Fedora packages"
sudo dnf install -y "${packages[@]}"

ensure_zsh_login_shell

success "Fedora packages installed"
