# macOS desktop integration for the portable theme command.
#
# The portable command owns the shared state files, tmux and the Ghostty
# guidance; a platform's desktop half belongs in a hook, so macOS gets one
# rather than the portable command growing a `case $(uname)`. See
# docs/workflows/theming.md, "Writing a theme hook", for the contract this
# file is written against.
#
# The wallpaper primitive, the interface it uses and what that interface
# depends on are in platforms/macos/lib/macos.sh, next to the AppleScript.

# shellcheck source=/dev/null
source "$DOTFILES_ROOT/platforms/macos/lib/macos.sh"

# shellcheck disable=SC2154 # $flavour is set by the sourcing theme command.
case "$flavour" in
latte | frappe | macchiato | mocha) ;;
*)
  printf 'macOS: refusing invalid Catppuccin flavour: %s\n' "$flavour" >&2
  return 1
  ;;
esac

# --preserve-wallpaper is a first-class outcome rather than an absence: a run
# that deliberately left the desktop alone should say so, and must not read as
# the same thing as a Mac where the wallpaper failed to apply. Nothing is
# snapshotted and nothing is restored; the mutation simply does not happen.
# shellcheck disable=SC2154 # $preserve_wallpaper is set by the theme command.
if [[ "$preserve_wallpaper" == true ]]; then
  theme_action_skipped macos:wallpaper '--preserve-wallpaper was requested'
else
  apply_macos_wallpaper() {
    macos_set_wallpaper "$(macos_wallpaper_for_flavour "$flavour")"
  }
  theme_action macos:wallpaper apply_macos_wallpaper
fi
