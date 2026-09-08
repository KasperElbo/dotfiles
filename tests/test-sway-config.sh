#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fedora_stow="$repo_root/platforms/fedora/stow"
config="$fedora_stow/sway/.config/sway/config"
waybar="$fedora_stow/waybar/.config/waybar/config.jsonc"
grid="$fedora_stow/sway/.local/bin/sway-workspace-grid"
session_start="$fedora_stow/sway/.local/bin/sway-session-start"
portal_config="$fedora_stow/sway/.config/xdg-desktop-portal/sway-portals.conf"
theme_hook="$fedora_stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh"
wallpaper_package="$fedora_stow/theme-assets/.local/share/wallpapers"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

command -v stow >/dev/null 2>&1 || {
  printf 'GNU Stow is required for Sway configuration tests.\n' >&2
  exit 1
}

# The dollar-prefixed strings below are literal Sway variables.
# shellcheck disable=SC2016
grep -Fq 'set $alt Mod1' "$config"
# shellcheck disable=SC2016
for shortcut in \
  'bindsym $mod+Return exec ghostty' \
  'bindsym $mod+p exec fuzzel' \
  'bindsym $mod+Shift+c kill' \
  'bindsym $mod+f fullscreen toggle' \
  'bindsym $mod+$alt+k input type:keyboard xkb_switch_layout next' \
  'bindsym $mod+Shift+s exec sway-screenshot region' \
  'bindsym $mod+Ctrl+$left exec sway-workspace-grid left'; do
  grep -Fq "$shortcut" "$config"
done

grep -Fq 'input type:keyboard {' "$config"
grep -Fq 'xkb_layout "us,dk"' "$config"

# Keep hardware controls intact when adding keyboard input configuration.
for binding in \
  'bindsym XF86AudioRaiseVolume exec wpctl set-volume' \
  'bindsym XF86AudioLowerVolume exec wpctl set-volume' \
  'bindsym XF86AudioMute exec wpctl set-mute' \
  'bindsym XF86AudioMicMute exec wpctl set-mute' \
  'bindsym XF86MonBrightnessUp exec brightnessctl' \
  'bindsym XF86MonBrightnessDown exec brightnessctl' \
  'bindsym XF86AudioPlay exec playerctl play-pause' \
  'bindsym XF86AudioNext exec playerctl next' \
  'bindsym XF86AudioPrev exec playerctl previous'; do
  grep -Fq "$binding" "$config"
done

grep -Fq 'exec /usr/libexec/lxqt-policykit-agent' "$config"
grep -Fq 'exec sway-session-start' "$config"
grep -Fq 'for_window [class="^xwaylandvideobridge$"] move scratchpad' "$config"

grep -Fq "timeout 600" "$config"
grep -Fq "timeout 900" "$config"
if grep -Ev '^[[:space:]]*#' "$config" | grep -Eq 'suspend|hibernate'; then
  printf 'Sway config must not suspend or hibernate automatically.\n' >&2
  exit 1
fi

for module in \
  sway/workspaces sway/window tray custom/power-profile sway/language network bluetooth \
  pulseaudio battery clock; do
  grep -Fq "\"$module\"" "$waybar"
done

grep -Fq '"format": "{short}"' "$waybar"
grep -Fq \
  '"on-click": "swaymsg input type:keyboard xkb_switch_layout next"' \
  "$waybar"
grep -Fq '#language' \
  "$fedora_stow/waybar/.config/waybar/style.css"

# Backticks are literal Markdown delimiters.
# shellcheck disable=SC2016
grep -Fq '| `Super+Alt+K` | Switch between US and Danish keyboard layouts |' \
  "$repo_root/README.md"

stow_home="$test_root/home"
mkdir -p \
  "$stow_home/.config/sway" \
  "$stow_home/.config/waybar" \
  "$stow_home/.local/share/wallpapers"
# Simulate links created by the pre-boundary layout. They are dangling after
# the tracked package directories move and must be replaced safely.
ln -s "$repo_root/sway/.config/sway/config" \
  "$stow_home/.config/sway/config"
ln -s "$repo_root/waybar/.config/waybar/config.jsonc" \
  "$stow_home/.config/waybar/config.jsonc"
ln -s \
  "$fedora_stow/sway/.local/share/wallpapers/catppuccin-macchiato.webp" \
  "$stow_home/.local/share/wallpapers/catppuccin-macchiato.webp"
HOME="$stow_home" \
  XDG_CONFIG_HOME="$stow_home/.config" \
  XDG_DATA_HOME="$stow_home/.local/share" \
  "$repo_root/scripts/setup-local.sh" macchiato --sway >/dev/null
HOME="$stow_home" \
  XDG_CONFIG_HOME="$stow_home/.config" \
  XDG_DATA_HOME="$stow_home/.local/share" \
  "$repo_root/scripts/stow.sh" --sway >/dev/null

[[ -L "$stow_home/.config/sway/config" ]]
[[ -L "$stow_home/.config/xdg-desktop-portal/sway-portals.conf" ]]
[[ -L "$stow_home/.config/waybar/config.jsonc" ]]
[[ -L "$stow_home/.local/bin/sway-workspace-grid" ]]
[[ -L "$stow_home/.local/bin/sway-session-start" ]]
[[ -L "$stow_home/.local/share/wallpapers/catppuccin-macchiato.webp" ]]
[[ "$(readlink -f "$stow_home/.config/sway/config")" == "$config" ]]
[[ "$(readlink -f "$stow_home/.config/waybar/config.jsonc")" == "$waybar" ]]
[[ -f "$stow_home/.config/sway/local.conf" ]]
[[ ! -L "$stow_home/.config/sway/local.conf" ]]

asset_home="$test_root/asset-home"
mkdir -p "$asset_home"
stow_theme_assets() {
  HOME="$asset_home" \
    XDG_CONFIG_HOME="$asset_home/.config" \
    XDG_DATA_HOME="$asset_home/.local/share" \
    "$repo_root/scripts/stow.sh" >/dev/null
}
stow_theme_assets
stow_theme_assets
[[ -L "$asset_home/.local/share/wallpapers/catppuccin-mocha.webp" ]]
[[ "$(readlink -f "$asset_home/.local/share/wallpapers/catppuccin-mocha.webp")" == \
  "$wallpaper_package/catppuccin-mocha.webp" ]]

mkdir -p "$test_root/bin" "$test_root/state"
cat >"$test_root/bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-t get_workspaces -r' ]]; then
  printf '[{"focused":true,"num":%s}]\n' "$CURRENT_WORKSPACE"
else
  printf '%s\n' "$*" >"$GRID_RESULT"
fi
EOF
cat >"$test_root/bin/jq" <<'EOF'
#!/usr/bin/env bash
# Consume the producer's input so the Bash mock does not receive SIGPIPE.
cat >/dev/null
printf '%s\n' "$CURRENT_WORKSPACE"
EOF
chmod +x "$test_root/bin/swaymsg"
chmod +x "$test_root/bin/jq"

assert_grid() {
  local current="$1"
  local direction="$2"
  local expected="$3"

  CURRENT_WORKSPACE="$current" \
    GRID_RESULT="$test_root/state/result" \
    PATH="$test_root/bin:$PATH" \
    "$grid" "$direction"
  grep -Fqx "workspace number $expected" "$test_root/state/result"
}

assert_grid 1 left 3
assert_grid 1 up 7
assert_grid 3 right 1
assert_grid 7 down 1
assert_grid 5 right 6
assert_grid 5 up 2

for flavour in latte frappe macchiato mocha; do
  wallpaper="$wallpaper_package/catppuccin-$flavour.webp"
  lock_wallpaper="$wallpaper_package/catppuccin-$flavour-lock.webp"
  [[ -s "$wallpaper" ]]
  [[ -s "$lock_wallpaper" ]]
done

bash -n "$grid"
bash -n "$fedora_stow/sway/.local/bin/sway-screenshot"
bash -n "$fedora_stow/sway/.local/bin/power-profile-status"
bash -n "$session_start"
bash -n "$repo_root/platforms/fedora/assets/dotfiles-sway"

grep -Fq 'session_script=/usr/libexec/sway-systemd/session.sh' "$session_start"
grep -Fq 'systemctl --user is-active --quiet graphical-session.target' "$session_start"
grep -Fq 'systemctl --user restart xdg-desktop-portal.service' "$session_start"
grep -Fq 'dex-autostart --autostart --environment sway' "$session_start"
grep -Fqx 'default=gtk' "$portal_config"
grep -Fqx 'org.freedesktop.impl.portal.Screenshot=wlr' "$portal_config"
grep -Fqx 'org.freedesktop.impl.portal.ScreenCast=wlr' "$portal_config"

target_line="$(grep -n 'is-active --quiet graphical-session.target' "$session_start" | cut -d: -f1)"
portal_line="$(grep -n 'restart xdg-desktop-portal.service' "$session_start" | cut -d: -f1)"
autostart_line="$(grep -n 'dex-autostart --autostart' "$session_start" | cut -d: -f1)"
if ((target_line >= portal_line || portal_line >= autostart_line)); then
  printf 'Graphical target, portal, and XDG autostart order is invalid.\n' >&2
  exit 1
fi

grep -Fq 'sway_args+=(--unsupported-gpu)' \
  "$repo_root/platforms/fedora/assets/dotfiles-sway"
grep -Fqx 'Exec=/usr/local/bin/dotfiles-sway' \
  "$repo_root/platforms/fedora/assets/dotfiles-sway.desktop"

# Waybar must be signalled before Sway reloads and recreates its managed bar.
waybar_reload_line="$(grep -n 'pkill -SIGUSR2 waybar' "$theme_hook" | cut -d: -f1)"
sway_reload_line="$(grep -n 'swaymsg reload' "$theme_hook" | cut -d: -f1)"
if [[ -z "$waybar_reload_line" || -z "$sway_reload_line" ]] ||
  ((waybar_reload_line >= sway_reload_line)); then
  printf 'Waybar reload must happen before the Sway reload.\n' >&2
  exit 1
fi

printf 'Sway configuration and 3x3 workspace navigation tests passed.\n'
