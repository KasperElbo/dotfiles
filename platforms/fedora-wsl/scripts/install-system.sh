#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/bootstrap-tools.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/bootstrap-tools.sh"
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
  gawk
  gcc
  gcc-c++
  gh
  git
  git-delta
  gzip
  jq
  libicu
  make
  neovim
  openssh-clients
  procps-ng
  ripgrep
  ShellCheck
  shadow-utils
  sqlite
  sqlite-devel
  stow
  tar
  tmux
  unzip
  zoxide
  zsh
  zsh-autosuggestions
  zsh-syntax-highlighting
)

info "Installing Fedora WSL command-line prerequisites"
sudo dnf install -y "${packages[@]}"

ensure_zsh_login_shell

if [[ "${ZSH_LOGIN_SHELL_CHANGED:-false}" == "true" ]]; then
  cat <<'EOF'

Zsh is now configured as your login shell.
This Noctty session was started before that change; open a new Noctty/WSL
session to enter Zsh normally.
EOF
fi

# A fresh Fedora WSL account does not necessarily have this XDG user binary
# directory yet. Both the Starship and mise installers require its parent
# directory to exist before they can place their executables there.
mkdir -p "$HOME/.local/bin"

# Both come from a pinned release archive whose SHA-256 is checked before it is
# unpacked; no upstream install script runs (see common/lib/bootstrap-tools.sh).
if command_exists starship || [[ -x "$HOME/.local/bin/starship" ]]; then
  info "Starship is already installed"
else
  info "Installing the pinned Starship $BOOTSTRAP_STARSHIP_VERSION release as a user executable"
  install_bootstrap_tool starship "$HOME/.local/bin/starship"
fi

[[ -x "$HOME/.local/bin/starship" ]] || command_exists starship ||
  die "Starship installation did not produce an executable"

if command_exists mise || [[ -x "$HOME/.local/bin/mise" ]]; then
  info "mise is already installed"
else
  info "Installing the pinned mise $BOOTSTRAP_MISE_VERSION release as a Linux-native user executable"
  install_bootstrap_tool mise "$HOME/.local/bin/mise"
fi

[[ -x "$HOME/.local/bin/mise" ]] || command_exists mise ||
  die "mise installation did not produce a Linux executable"

success "Fedora WSL prerequisites installed"
