#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/theme-state.sh
source "$DOTFILES_ROOT/common/lib/theme-state.sh"
# shellcheck source=../lib/theme-state.sh
source "$DOTFILES_ROOT/platforms/fedora/lib/theme-state.sh"

theme="${1:-macchiato}"
install_sway="false"
hardware_model=""
shift || true

while (($#)); do
  case "$1" in
  --sway)
    install_sway="true"
    ;;
  --hardware)
    [[ $# -ge 2 ]] || die "--hardware requires a value"
    hardware_model="$2"
    shift
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
  shift
done

case "$hardware_model" in
"" | ga402xz | ga402rk)
  ;;
*)
  die "Invalid hardware profile: $hardware_model"
  ;;
esac

"$DOTFILES_ROOT/common/setup-local.sh" "$theme"

current_theme="$(cat "$XDG_CONFIG_HOME/dotfiles/theme")"
write_fedora_theme_state "$current_theme"

if [[ "$install_sway" == "true" ]]; then
  sway_dir="$XDG_CONFIG_HOME/sway"
  ensure_dir "$sway_dir"

  if [[ ! -e "$sway_dir/local.conf" ]]; then
    {
      cat <<'EOF'
# Machine-local output configuration. This file is intentionally untracked.
# Discover output names with: swaymsg -t get_outputs
#
# Examples:
# output eDP-1 scale 1.5
# output DP-1 position 0 0
# output HDMI-A-1 position 2560 0
EOF
      if [[ "$hardware_model" == "ga402xz" ]]; then
        cat <<'EOF'

# The GA402XZ panel is intentionally used without HiDPI scaling.
output eDP-1 scale 1
EOF
      fi
    } | atomic_write_file "$sway_dir/local.conf"
    info "Created local Sway output override: $sway_dir/local.conf"
  else
    info "Keeping existing local Sway output override: $sway_dir/local.conf"
  fi
fi

success "Fedora-local configuration initialized"
