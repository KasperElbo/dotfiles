#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/preflight.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

require_command stow

install_sway="false"

while (($#)); do
  case "$1" in
  --sway)
    install_sway="true"
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
  shift
done

packages=(zsh-platform theme-hooks theme-assets)

if [[ "$install_sway" == "true" ]]; then
  packages+=(sway waybar)
fi

# Checked before common/stow.sh links anything, which checks its own packages
# the same way, so no conflict is found after part of HOME is already stowed.
# The retired links the apply loop removes below are exempted here, from the
# same list the installer's own preflight reads, so both agree.
specs=()
replaced=()
for package in "${packages[@]}"; do
  specs+=("$FEDORA_STOW_DIR::$package")
done
while IFS= read -r exemption; do
  replaced+=("$exemption")
done < <(fedora_retired_link_exemptions "${packages[@]}")
preflight_stow_packages ${replaced[@]+"${replaced[@]}"} "${specs[@]}" ||
  die "Refusing to stow; nothing in $HOME was changed."

"$DOTFILES_ROOT/common/stow.sh"

info "Stowing Fedora user integration into $HOME"

for package in "${packages[@]}"; do
  package_dir="$FEDORA_STOW_DIR/$package"

  [[ -d "$package_dir" ]] || die "Missing Fedora Stow package: $package"

  while IFS= read -r retired_link; do
    info "Removing retired $package link: $retired_link"
    rm -- "$retired_link"
  done < <(fedora_retired_stow_links "$package")

  info "Stowing Fedora package $package"
  stow \
    --dir="$FEDORA_STOW_DIR" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Fedora user integration stowed"
