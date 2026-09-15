#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/fetch.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

non_interactive="false"
while (($#)); do
  case "$1" in
  --non-interactive) non_interactive="true" ;;
  *) die "Unknown option: $1" ;;
  esac
  shift
done

require_apple_silicon_macos

if [[ -x /usr/local/bin/brew ]]; then
  die "Intel Homebrew exists at /usr/local/bin/brew. Resolve that duplicate before installing this profile."
fi

if ! xcode-select -p >/dev/null 2>&1; then
  die "Apple Command Line Tools are required. Run 'xcode-select --install', finish the dialog, then rerun."
fi

brew_bin="$(homebrew_path)"
if [[ ! -x "$brew_bin" ]]; then
  require_command curl
  info "Installing native Apple Silicon Homebrew"
  installer="$(mktemp -t dotfiles-homebrew.XXXXXX)"
  trap 'rm -f -- "$installer"' EXIT
  # network-source: homebrew-installer
  fetch_to_file https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    "$installer" 'the Homebrew installer'
  fetch_assert_shell_script "$installer" 'the Homebrew installer'
  if [[ "$non_interactive" == true ]]; then
    NONINTERACTIVE=1 /bin/bash "$installer"
  else
    /bin/bash "$installer"
  fi
fi

require_native_homebrew
activate_homebrew_path

info "Installing Homebrew-owned workstation packages"
"$brew_bin" bundle --file="$DOTFILES_ROOT/platforms/macos/Brewfile"

ensure_macos_zsh_login_shell
if [[ "${ZSH_LOGIN_SHELL_CHANGED:-false}" == "true" ]]; then
  warn "Login shell changed; open a new terminal session before expecting Zsh."
fi

success "macOS system packages installed"
