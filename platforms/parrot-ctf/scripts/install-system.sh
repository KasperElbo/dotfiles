#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

require_parrot
require_qemu_vm >/dev/null

# This is intentionally a working-environment list, not a duplicate of
# Parrot Security Edition's offensive-security catalogue.
packages=(
  bat
  build-essential
  ca-certificates
  curl
  eza
  fd-find
  fzf
  gh
  git
  git-delta
  jq
  lazygit
  neovim
  pipx
  python-is-python3
  python3
  python3-dev
  python3-pip
  python3-venv
  ripgrep
  shellcheck
  sqlite3
  starship
  stow
  tmux
  unzip
  zoxide
  zsh
  zsh-autosuggestions
  zsh-syntax-highlighting
)

info "Refreshing Parrot package metadata"
sudo apt-get update

info "Installing the Parrot CTF working environment"
sudo apt-get install -y --no-install-recommends "${packages[@]}"

current_user="$(id -un)"
login_shell="$(getent passwd "$current_user")"
login_shell="${login_shell##*:}"
if [[ "$login_shell" == */zsh ]]; then
  info "Zsh is already the default login shell"
else
  info "Setting Zsh as the default login shell"
  sudo usermod --shell /bin/zsh "$current_user"
fi

mkdir -p "$HOME/.local/bin"
if command_exists mise || [[ -x "$HOME/.local/bin/mise" ]]; then
  info "mise is already installed"
else
  installer="$(mktemp)"
  trap 'rm -f -- "$installer"' EXIT
  info "Downloading the official mise installer"
  curl --fail --show-error --silent --location \
    --proto '=https' --tlsv1.2 https://mise.run --output "$installer"
  MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh "$installer"
fi

[[ -x "$HOME/.local/bin/mise" ]] || command_exists mise ||
  die "mise installation did not produce an executable"

success "Parrot CTF working environment installed"
