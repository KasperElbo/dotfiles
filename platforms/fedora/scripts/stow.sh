#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/preflight.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

# Stow is given one target, $HOME. An XDG root pointing anywhere else would
# have it link configuration where nothing later reads it, so that is refused
# before a single link is made -- and before the prerequisite check below, so
# the answer does not depend on whether Stow happens to be installed.
preflight_xdg_layout || die "Refusing to stow; nothing in $HOME was changed."

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

# theme-assets is at the top of the checkout rather than under
# platforms/fedora/stow, because the wallpapers are not Fedora's: they are one
# set of images any platform can link. Its root is resolved rather than assumed
# for that reason, through the same helper the installer's preflight uses.
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
  specs+=("$(capability_stow_package_root fedora "$package")::$package")
done
while IFS= read -r exemption; do
  replaced+=("$exemption")
done < <(fedora_retired_link_exemptions "${packages[@]}")
preflight_stow_packages ${replaced[@]+"${replaced[@]}"} "${specs[@]}" ||
  die "Refusing to stow; nothing in $HOME was changed."

"$DOTFILES_ROOT/common/stow.sh"

info "Stowing Fedora user integration into $HOME"

for package in "${packages[@]}"; do
  package_dir="$(capability_stow_package_root fedora "$package")/$package"

  [[ -d "$package_dir" ]] || die "Missing Stow package: $package"

  while IFS= read -r retired_link; do
    info "Removing retired $package link: $retired_link"
    rm -- "$retired_link"
  done < <(fedora_retired_stow_links "$package")

  info "Stowing package $package"
  stow \
    --dir="$(dirname "$package_dir")" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Fedora user integration stowed"
