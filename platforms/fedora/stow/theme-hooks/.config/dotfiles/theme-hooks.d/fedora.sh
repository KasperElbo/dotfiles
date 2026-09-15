# Fedora desktop integration for the portable theme command.
#
# Every effect is a named action with its own error boundary (issue #148): a
# KDE apply that fails must not stop the Sway reload, and must not let the
# command report a complete application afterwards.

# shellcheck source=/dev/null
source "$DOTFILES_ROOT/platforms/fedora/lib/theme-state.sh"

# shellcheck disable=SC2154
theme_action fedora:generated-state \
  write_fedora_theme_state "$flavour" "$preserve_wallpaper"

sway_session_active="false"
if command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; then
  sway_session_active="true"
fi

# --- KDE -------------------------------------------------------------------
#
# Applying the KDE global theme names an identifier such as
# Catppuccin-Mocha-Mauve. Naming one that was never installed is exactly the
# failure #148 is about, so this asks three separate questions: was the KDE
# capability installed, are the assets actually on disk, and is a KDE session
# the thing being themed right now.

kde_global_theme() {
  case "$1" in
  latte) printf 'Catppuccin-Latte-Mauve\n' ;;
  frappe) printf 'Catppuccin-Frappe-Mauve\n' ;;
  macchiato) printf 'Catppuccin-Macchiato-Mauve\n' ;;
  mocha) printf 'Catppuccin-Mocha-Mauve\n' ;;
  *) return 1 ;;
  esac
}

kde_assets_installed() {
  local theme_name
  theme_name="$(kde_global_theme "$1")" || return 1
  [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/plasma/look-and-feel/$theme_name" ]]
}

kde_commands_available() {
  command -v lookandfeeltool >/dev/null 2>&1 &&
    command -v plasma-apply-colorscheme >/dev/null 2>&1 &&
    command -v plasma-apply-cursortheme >/dev/null 2>&1
}

apply_kde_theme() {
  local args=("$flavour")
  [[ "$preserve_wallpaper" != "true" ]] || args+=(--preserve-wallpaper)
  "$DOTFILES_ROOT/platforms/fedora/scripts/apply-kde-theme.sh" "${args[@]}"
}

if [[ "$sway_session_active" == "true" ]]; then
  theme_action_skipped fedora:kde 'a Sway session is running'
elif theme_capability_known_absent kde; then
  # The decisive check for `--no-kde`: this machine recorded an installation
  # that did not include KDE, so there are no Catppuccin KDE assets to name.
  theme_action_skipped fedora:kde 'the KDE capability was not installed'
elif ! kde_assets_installed "$flavour"; then
  # Also covers a machine installed before the capability was recorded: no
  # assets, no apply, whatever the state file does or does not say.
  theme_action_skipped fedora:kde "Catppuccin KDE assets for $flavour are not installed"
elif ! kde_commands_available; then
  theme_action_skipped fedora:kde 'the Plasma theming commands are not available'
else
  theme_action fedora:kde apply_kde_theme
fi

# --- Ghostty ---------------------------------------------------------------
#
# Ghostty applies a changed `theme` only on a full restart. Reloading is still
# worth doing for everything else in the config, but claiming the new palette
# is live would be untrue, so the message says what actually has to happen.

reload_ghostty() {
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl --user is-active --quiet app-com.mitchellh.ghostty.service 2>/dev/null; then
    systemctl reload --user app-com.mitchellh.ghostty.service && return 0
  fi

  if command -v pgrep >/dev/null 2>&1 && command -v pkill >/dev/null 2>&1 &&
    pgrep -x ghostty >/dev/null 2>&1; then
    pkill -USR2 -x ghostty && return 0
  fi

  return 1
}

theme_note_ghostty_handled
if reload_ghostty; then
  echo "Ghostty: configuration reload requested."
  echo "         Restart Ghostty to apply catppuccin-$flavour; a reload does not"
  echo "         change an already-set theme."
else
  echo "Ghostty: no running instance reloaded; new windows use catppuccin-$flavour."
fi

# --- Sway ------------------------------------------------------------------

reload_sway_session() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -SIGUSR2 waybar >/dev/null 2>&1 || true
  fi

  swaymsg reload >/dev/null || return 1

  if command -v makoctl >/dev/null 2>&1; then
    makoctl reload >/dev/null 2>&1 || true
  fi
}

if [[ "$sway_session_active" == "true" ]]; then
  theme_action fedora:sway reload_sway_session
fi
