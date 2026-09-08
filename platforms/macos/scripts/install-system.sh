#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
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
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    --output "$installer"
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

success "macOS system packages installed"
