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
  firewalld
  gh
  git
  git-delta
  gnupg2
  jq
  libicu
  neovim
  openssh-clients
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
sudo systemctl enable --now firewalld.service

ensure_zsh_login_shell
if [[ "${ZSH_LOGIN_SHELL_CHANGED:-false}" == "true" ]]; then
  warn "Login shell changed; reboot before expecting Ghostty to use Zsh. Plasma and user services can retain the previous SHELL value until then."
fi

success "Fedora packages installed"
