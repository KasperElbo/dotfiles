#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/bootstrap-tools.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/bootstrap-tools.sh"
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
  fontconfig
  fzf
  gh
  git
  git-delta
  jq
  konsole
  lazygit
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
  xclip
  xdg-utils
  xxd
  xz-utils
  zoxide
  zsh
  zsh-autosuggestions
  zsh-syntax-highlighting
)

info "Refreshing Parrot package metadata"
sudo apt-get update

info "Installing the Parrot CTF working environment"
sudo apt-get install -y --no-install-recommends "${packages[@]}"

REQUIRE_REGISTERED_LOGIN_SHELL=true ensure_zsh_login_shell

mkdir -p "$HOME/.local/bin"
if command_exists mise || [[ -x "$HOME/.local/bin/mise" ]]; then
  info "mise is already installed"
else
  # A pinned release archive, checked by SHA-256 before it is unpacked; no
  # upstream install script runs (see common/lib/bootstrap-tools.sh).
  info "Installing the pinned mise $BOOTSTRAP_MISE_VERSION release"
  install_bootstrap_tool mise "$HOME/.local/bin/mise"
fi

[[ -x "$HOME/.local/bin/mise" ]] || command_exists mise ||
  die "mise installation did not produce an executable"

success "Parrot CTF working environment installed"
