#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

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

"$DOTFILES_ROOT/common/stow.sh"

platform_stow_dir="$DOTFILES_ROOT/platforms/fedora/stow"
packages=(zsh-platform theme-hooks)

if [[ "$install_sway" == "true" ]]; then
  packages+=(sway waybar)
fi

migrate_moved_package_links() {
  local package="$1"
  local source_path
  local relative_path
  local target_path
  local resolved_target

  while IFS= read -r -d '' source_path; do
    relative_path="${source_path#"$platform_stow_dir/$package/"}"
    target_path="$HOME/$relative_path"

    [[ -L "$target_path" ]] || continue
    resolved_target="$(realpath -m "$target_path")"

    if [[ "$resolved_target" == "$DOTFILES_ROOT/$package/"* ]]; then
      info "Removing moved $package link: $target_path"
      rm -- "$target_path"
    fi
  done < <(find "$platform_stow_dir/$package" -type f -print0)
}

info "Stowing Fedora user integration into $HOME"

for package in "${packages[@]}"; do
  package_dir="$platform_stow_dir/$package"

  [[ -d "$package_dir" ]] || die "Missing Fedora Stow package: $package"

  if [[ "$package" == sway || "$package" == waybar ]]; then
    migrate_moved_package_links "$package"
  fi

  info "Stowing Fedora package $package"
  stow \
    --dir="$platform_stow_dir" \
    --target="$HOME" \
    --restow \
    --no-folding \
    "$package"
done

success "Fedora user integration stowed"
