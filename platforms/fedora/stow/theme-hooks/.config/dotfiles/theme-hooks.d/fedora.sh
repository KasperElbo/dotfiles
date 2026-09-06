# Fedora desktop integration for the portable theme command.

# shellcheck source=/dev/null
source "$DOTFILES_ROOT/platforms/fedora/lib/theme-state.sh"

# shellcheck disable=SC2154
write_fedora_theme_state "$flavour" "$preserve_wallpaper"

if command -v lookandfeeltool >/dev/null 2>&1 \
  && command -v plasma-apply-colorscheme >/dev/null 2>&1 \
  && command -v plasma-apply-cursortheme >/dev/null 2>&1; then
  kde_theme_args=("$flavour")
  if [[ "$preserve_wallpaper" == "true" ]]; then
    kde_theme_args+=(--preserve-wallpaper)
  fi
  "$DOTFILES_ROOT/platforms/fedora/scripts/apply-kde-theme.sh" \
    "${kde_theme_args[@]}"
fi

ghostty_reloaded="false"

if command -v systemctl >/dev/null 2>&1 \
  && systemctl --user is-active --quiet app-com.mitchellh.ghostty.service 2>/dev/null; then
  if systemctl reload --user app-com.mitchellh.ghostty.service; then
    ghostty_reloaded="true"
  fi
fi

if [[ "$ghostty_reloaded" == "false" ]] \
  && command -v pgrep >/dev/null 2>&1 \
  && command -v pkill >/dev/null 2>&1 \
  && pgrep -x ghostty >/dev/null 2>&1; then
  if pkill -USR2 -x ghostty; then
    ghostty_reloaded="true"
  fi
fi

if [[ "$ghostty_reloaded" == "false" ]]; then
  echo "Ghostty: reload with Ctrl-Shift-, if currently running."
fi

if command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; then
  if command -v pkill >/dev/null 2>&1; then
    pkill -SIGUSR2 waybar >/dev/null 2>&1 || true
  fi

  swaymsg reload >/dev/null

  if command -v makoctl >/dev/null 2>&1; then
    makoctl reload >/dev/null 2>&1 || true
  fi
fi
