# macOS desktop integration for the portable theme command.
#
# The portable command owns the shared state files, tmux and the Ghostty
# guidance; a platform's desktop half belongs in a hook, so macOS gets one
# rather than the portable command growing a `case $(uname)`. See
# docs/workflows/theming.md, "Writing a theme hook", for the contract this
# file is written against.
#
# It applies nothing yet. The wallpaper mutation is issue #278, and until that
# lands this reports the wallpaper as skipped with the reason, because a hook
# that stayed silent would let `theme` claim a complete application on a Mac
# whose desktop did not change.

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
# the same thing as a Mac where the wallpaper failed to apply.
# shellcheck disable=SC2154 # $preserve_wallpaper is set by the theme command.
if [[ "$preserve_wallpaper" == true ]]; then
  theme_action_skipped macos:wallpaper \
    '--preserve-wallpaper was requested'
else
  theme_action_skipped macos:wallpaper \
    "setting the desktop wallpaper on macOS is not implemented yet (issue #278)"
fi
