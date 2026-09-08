#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/theme-state.sh
source "$DOTFILES_ROOT/platforms/fedora/lib/theme-state.sh"

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
  ;;
frappe)
  global_theme="Catppuccin-Frappe-Mauve"
  color_scheme="CatppuccinFrappeMauve"
  ;;
macchiato)
  global_theme="Catppuccin-Macchiato-Mauve"
  color_scheme="CatppuccinMacchiatoMauve"
  ;;
mocha)
  global_theme="Catppuccin-Mocha-Mauve"
  color_scheme="CatppuccinMochaMauve"
  ;;
*)
  echo "Usage: $0 {latte|frappe|macchiato|mocha}" >&2
  exit 1
  ;;
esac

cursor_theme="$(fedora_theme_cursor_theme "$flavour")"

echo "Applying Catppuccin $flavour to KDE..."

qdbus_command=""
wallpaper_snapshot=""
wallpaper="$(fedora_theme_wallpaper "$flavour")"
lock_wallpaper="$(fedora_theme_lock_wallpaper "$flavour")"

for candidate in qdbus6 qdbus; do
  if command -v "$candidate" >/dev/null 2>&1; then
    qdbus_command="$candidate"
    break
  fi
done

if [[ "$preserve_wallpaper" == "true" ]]; then
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
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 \
      --file kwinrc \
      --group org.kde.kdecoration2 \
      --key BorderSizeAuto false
  fi
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

if [[ "$preserve_wallpaper" != "true" ]]; then
  if [[ ! -f "$wallpaper" ]]; then
    warn "KDE wallpaper is missing: $wallpaper"
  elif command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
    plasma-apply-wallpaperimage "$wallpaper"
  else
    warn "plasma-apply-wallpaperimage is unavailable; KDE wallpaper was not changed"
  fi
fi

if [[ ! -f "$lock_wallpaper" ]]; then
  warn "KDE lock-screen wallpaper is missing: $lock_wallpaper"
elif command -v kwriteconfig6 >/dev/null 2>&1; then
  kwriteconfig6 \
    --file kscreenlockerrc \
    --group Greeter \
    --key WallpaperPlugin org.kde.image

  for key in Image PreviewImage; do
    kwriteconfig6 \
      --file kscreenlockerrc \
      --group Greeter \
      --group Wallpaper \
      --group org.kde.image \
      --group General \
      --key "$key" "$lock_wallpaper"
  done
else
  warn "kwriteconfig6 is unavailable; KDE lock-screen wallpaper was not changed"
fi

plasma-apply-colorscheme "$color_scheme"
plasma-apply-cursortheme "$cursor_theme"
