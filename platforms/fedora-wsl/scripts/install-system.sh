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
  gawk
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
  shadow-utils
  sqlite
  sqlite-devel
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

ensure_zsh_login_shell

# A fresh Fedora WSL account does not necessarily have this XDG user binary
# directory yet. Both the Starship and mise installers require its parent
# directory to exist before they can place their executables there.
mkdir -p "$HOME/.local/bin"

if command_exists starship || [[ -x "$HOME/.local/bin/starship" ]]; then
  info "Starship is already installed"
else
  starship_installer="$(mktemp)"
  trap 'rm -f -- "${installer:-}" "${starship_installer:-}"' EXIT

  info "Downloading the official Starship installer"
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 \
    https://starship.rs/install.sh \
    --output "$starship_installer"

  info "Installing Starship as a user executable"
  sh "$starship_installer" --yes --bin-dir "$HOME/.local/bin"
fi

[[ -x "$HOME/.local/bin/starship" ]] || command_exists starship ||
  die "Starship installation did not produce an executable"

if command_exists mise || [[ -x "$HOME/.local/bin/mise" ]]; then
  info "mise is already installed"
else
  installer="$(mktemp)"
  trap 'rm -f -- "$installer" "${starship_installer:-}"' EXIT

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
