#!/usr/bin/env bash
set -euo pipefail

flavour="${1:-}"
preserve_wallpaper="false"

if [[ "${2:-}" == "--preserve-wallpaper" ]]; then
  preserve_wallpaper="true"
  shift
fi
shift || true

if (($#)); then
  echo "Unknown option: $1" >&2
  exit 1
fi

case "$flavour" in
latte)
  global_theme="Catppuccin-Latte-Mauve"
  color_scheme="CatppuccinLatteMauve"
  cursor_theme="catppuccin-latte-mauve-cursors"
  ;;
frappe)
  global_theme="Catppuccin-Frappe-Mauve"
  color_scheme="CatppuccinFrappeMauve"
  cursor_theme="catppuccin-frappe-mauve-cursors"
  ;;
macchiato)
  global_theme="Catppuccin-Macchiato-Mauve"
  color_scheme="CatppuccinMacchiatoMauve"
  cursor_theme="catppuccin-macchiato-mauve-cursors"
  ;;
mocha)
  global_theme="Catppuccin-Mocha-Mauve"
  color_scheme="CatppuccinMochaMauve"
  cursor_theme="catppuccin-mocha-mauve-cursors"
  ;;
*)
  echo "Usage: $0 {latte|frappe|macchiato|mocha}" >&2
  exit 1
  ;;
esac

echo "Applying Catppuccin $flavour to KDE..."

qdbus_command=""
wallpaper_snapshot=""

if [[ "$preserve_wallpaper" == "true" ]]; then
  for candidate in qdbus6 qdbus; do
    if command -v "$candidate" >/dev/null 2>&1; then
      qdbus_command="$candidate"
      break
    fi
  done

  if [[ -n "$qdbus_command" ]]; then
    read_wallpaper_script='function readGroup(item, path) {
  item.currentConfigGroup = path;
  var result = { values: {}, groups: {} };
  var keys = item.configKeys.concat([]);
  for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    result.values[keys[keyIndex]] = item.readConfig(keys[keyIndex]);
  }
  var groups = item.configGroups.concat([]);
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    var group = groups[groupIndex];
    result.groups[group] = readGroup(item, path.concat([group]));
  }
  return result;
}
var result = [];
var allDesktops = desktops();
for (var desktopIndex = 0; desktopIndex < allDesktops.length; desktopIndex++) {
  var desktop = allDesktops[desktopIndex];
  var plugin = desktop.wallpaperPlugin;
  result.push({
    id: desktop.id,
    plugin: plugin,
    config: readGroup(desktop, ["Wallpaper", plugin])
  });
}
print(JSON.stringify(result));'

    wallpaper_snapshot="$(
      "$qdbus_command" org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript "$read_wallpaper_script" \
        2>/dev/null || true
    )"
  fi

  if [[ "$wallpaper_snapshot" != \[*\] ]]; then
    printf '%s\n' \
      'KDE wallpaper state could not be read; skipping the global theme to preserve it.' \
      >&2
  fi
fi

if [[ "$preserve_wallpaper" != "true" || "$wallpaper_snapshot" == \[*\] ]]; then
  lookandfeeltool --apply "$global_theme"
fi

if [[ "$preserve_wallpaper" == "true" && "$wallpaper_snapshot" == \[*\] ]]; then
  escaped_snapshot="${wallpaper_snapshot//\\/\\\\}"
  escaped_snapshot="${escaped_snapshot//\'/\\\'}"
  escaped_snapshot="${escaped_snapshot//$'\n'/\\n}"
  escaped_snapshot="${escaped_snapshot//$'\r'/\\r}"

  restore_wallpaper_script="var snapshot = JSON.parse('$escaped_snapshot');
function restoreGroup(item, path, saved) {
  item.currentConfigGroup = path;
  var keys = Object.keys(saved.values);
  for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    var key = keys[keyIndex];
    item.writeConfig(key, saved.values[key]);
  }
  var groups = Object.keys(saved.groups);
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    var group = groups[groupIndex];
    restoreGroup(item, path.concat([group]), saved.groups[group]);
  }
}
for (var index = 0; index < snapshot.length; index++) {
  var saved = snapshot[index];
  var desktop = desktopById(saved.id);
  if (desktop) {
    desktop.wallpaperPlugin = saved.plugin;
    restoreGroup(desktop, ['Wallpaper', saved.plugin], saved.config);
  }
}"

  "$qdbus_command" org.kde.plasmashell /PlasmaShell \
    org.kde.PlasmaShell.evaluateScript "$restore_wallpaper_script" >/dev/null
fi

plasma-apply-colorscheme "$color_scheme"
plasma-apply-cursortheme "$cursor_theme"
