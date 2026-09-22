#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fedora_stow="$repo_root/platforms/fedora/stow"
config="$fedora_stow/sway/.config/sway/config"
waybar="$fedora_stow/waybar/.config/waybar/config.jsonc"
grid="$fedora_stow/sway/.local/bin/sway-workspace-grid"
cycle="$fedora_stow/sway/.local/bin/sway-output-cycle"
session_start="$fedora_stow/sway/.local/bin/sway-session-start"
portal_config="$fedora_stow/sway/.config/xdg-desktop-portal/sway-portals.conf"
theme_hook="$fedora_stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh"
wallpaper_package="$repo_root/theme-assets/.local/share/wallpapers"
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
  'bindsym $mod+Ctrl+$left exec sway-workspace-grid left' \
  'bindsym $mod+Tab exec sway-output-cycle focus next' \
  'bindsym $mod+Shift+Tab exec sway-output-cycle move-window next' \
  'bindsym $mod+Ctrl+Tab exec sway-output-cycle move-workspace next'; do
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
config_code="$(grep -Ev '^[[:space:]]*#' "$config" || true)"
if grep -Eq 'suspend|hibernate' <<<"$config_code"; then
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
  "$repo_root/docs/platforms/fedora.md"

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
  "$repo_root/platforms/fedora/scripts/setup-local.sh" macchiato --sway >/dev/null
HOME="$stow_home" \
  XDG_CONFIG_HOME="$stow_home/.config" \
  XDG_DATA_HOME="$stow_home/.local/share" \
  "$repo_root/platforms/fedora/scripts/stow.sh" --sway >/dev/null

[[ -L "$stow_home/.config/sway/config" ]]
[[ -L "$stow_home/.config/xdg-desktop-portal/sway-portals.conf" ]]
[[ -L "$stow_home/.config/waybar/config.jsonc" ]]
[[ -L "$stow_home/.local/bin/sway-workspace-grid" ]]
[[ -L "$stow_home/.local/bin/sway-output-cycle" ]]
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
    "$repo_root/platforms/fedora/scripts/stow.sh" >/dev/null
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

# Outside the 1-9 grid the script refuses instead of teleporting the user in
# from an invented origin, matching aerospace-workspace-grid word for word
# (the action registry describes both with the same sentence).
refusal="$test_root/state/refusal"
: >"$test_root/state/result"
status=0
CURRENT_WORKSPACE=10 \
  GRID_RESULT="$test_root/state/result" \
  PATH="$test_root/bin:$PATH" \
  "$grid" right 2>"$refusal" || status=$?
((status == 1)) || {
  printf 'sway-workspace-grid exited %s outside the grid, expected 1.\n' "$status" >&2
  exit 1
}
grep -Fqx 'Focused workspace is not in the 1-9 grid: 10' "$refusal"
[[ ! -s "$test_root/state/result" ]] || {
  printf 'sway-workspace-grid switched workspace despite refusing.\n' >&2
  exit 1
}

# A leading zero is a decimal workspace number, never octal.
status=0
CURRENT_WORKSPACE=08 \
  GRID_RESULT="$test_root/state/result" \
  PATH="$test_root/bin:$PATH" \
  "$grid" right 2>"$refusal" || status=$?
((status == 1)) || {
  printf 'sway-workspace-grid accepted the out-of-grid workspace 08.\n' >&2
  exit 1
}

# --- sway-output-cycle: the display operations, proved against a stub Sway ---
#
# Sway's own focus/move output commands take a direction and wrap along that
# axis only, so a vertically stacked pair is unreachable with "right". The
# script walks the sorted output list instead, which is what lets
# config/actions.tsv describe the Sway and AeroSpace display actions with the
# same three sentences. Its own bin directory keeps the real jq — a runner
# requirement in scripts/test.sh — ahead of the grid's stub above.
mkdir -p "$test_root/cycle-bin"
cat >"$test_root/cycle-bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-t get_outputs -r' ]]; then
  printf '%s\n' "$OUTPUTS_JSON"
else
  printf '%s\n' "$*" >"$CYCLE_RESULT"
fi
EOF
chmod +x "$test_root/cycle-bin/swaymsg"

cycle_result="$test_root/state/cycle-result"
cycle_error="$test_root/state/cycle-error"

run_cycle() {
  local outputs="$1"
  shift
  : >"$cycle_result"
  : >"$cycle_error"
  cycle_status=0
  OUTPUTS_JSON="$outputs" \
    CYCLE_RESULT="$cycle_result" \
    PATH="$test_root/cycle-bin:$PATH" \
    "$cycle" "$@" 2>"$cycle_error" || cycle_status=$?
}

assert_cycle() {
  local outputs="$1"
  local expected="$2"
  shift 2

  run_cycle "$outputs" "$@"
  ((cycle_status == 0)) || {
    printf 'sway-output-cycle %s exited %s: %s\n' \
      "$*" "$cycle_status" "$(cat "$cycle_error")" >&2
    exit 1
  }
  grep -Fqx "$expected" "$cycle_result" || {
    printf 'sway-output-cycle %s ran %s, expected %s\n' \
      "$*" "$(cat "$cycle_result")" "$expected" >&2
    exit 1
  }
}

# Three side-by-side outputs with the middle one focused.
three_outputs='[
  {"name":"DP-1","active":true,"focused":false,"rect":{"x":0,"y":0}},
  {"name":"eDP-1","active":true,"focused":true,"rect":{"x":1920,"y":0}},
  {"name":"HDMI-A-1","active":true,"focused":false,"rect":{"x":3840,"y":0}}
]'
assert_cycle "$three_outputs" 'focus output "HDMI-A-1"' focus next
assert_cycle "$three_outputs" 'focus output "DP-1"' focus prev
# AeroSpace moves the window with --focus-follows-window; Sway has to say so.
assert_cycle "$three_outputs" \
  'move container to output "HDMI-A-1"; focus output "HDMI-A-1"' move-window next
assert_cycle "$three_outputs" 'move workspace to output "HDMI-A-1"' move-workspace next
# next is the default, matching the three bindings in the Sway config.
assert_cycle "$three_outputs" 'focus output "HDMI-A-1"' focus

# The cycle wraps at the last output, as --wrap-around does.
assert_cycle '[
  {"name":"DP-1","active":true,"focused":false,"rect":{"x":0,"y":0}},
  {"name":"eDP-1","active":true,"focused":true,"rect":{"x":1920,"y":0}}
]' 'focus output "DP-1"' focus next

# The case Sway'"'"'s own "focus output right" cannot reach: a vertical stack.
assert_cycle '[
  {"name":"TOP","active":true,"focused":true,"rect":{"x":0,"y":0}},
  {"name":"BOTTOM","active":true,"focused":false,"rect":{"x":0,"y":1080}}
]' 'focus output "BOTTOM"' focus next

# A disconnected output is not a place to send a window to. It sits after the
# focused one, so leaving the filter out would land on it instead of wrapping.
assert_cycle '[
  {"name":"DP-1","active":true,"focused":false,"rect":{"x":0,"y":0}},
  {"name":"eDP-1","active":true,"focused":true,"rect":{"x":1920,"y":0}},
  {"name":"HDMI-A-1","active":false,"focused":false,"rect":{"x":3840,"y":0}}
]' 'focus output "DP-1"' focus next

# One output makes every operation a no-op rather than an error.
assert_cycle '[
  {"name":"eDP-1","active":true,"focused":true,"rect":{"x":0,"y":0}}
]' 'focus output "eDP-1"' focus next

# An unknown operation or direction is a usage error, and nothing runs.
for bogus in "sideways next" "focus sideways"; do
  # shellcheck disable=SC2086
  run_cycle "$three_outputs" $bogus
  ((cycle_status == 2)) || {
    printf 'sway-output-cycle %s exited %s, expected 2.\n' "$bogus" "$cycle_status" >&2
    exit 1
  }
  [[ ! -s "$cycle_result" ]] || {
    printf 'sway-output-cycle %s ran a command despite refusing.\n' "$bogus" >&2
    exit 1
  }
done

# Sway answering with no focused output is a refusal, not a guess at one.
run_cycle '[
  {"name":"DP-1","active":true,"focused":false,"rect":{"x":0,"y":0}},
  {"name":"eDP-1","active":true,"focused":false,"rect":{"x":1920,"y":0}}
]' focus next
((cycle_status == 1)) || {
  printf 'sway-output-cycle exited %s with no focused output, expected 1.\n' \
    "$cycle_status" >&2
  exit 1
}
grep -Fqx 'No focused output among the active ones: DP-1 eDP-1' "$cycle_error"
[[ ! -s "$cycle_result" ]] || {
  printf 'sway-output-cycle moved focus despite refusing.\n' >&2
  exit 1
}

for flavour in latte frappe macchiato mocha; do
  wallpaper="$wallpaper_package/catppuccin-$flavour.webp"
  lock_wallpaper="$wallpaper_package/catppuccin-$flavour-lock.webp"
  [[ -s "$wallpaper" ]]
  [[ -s "$lock_wallpaper" ]]
done

# The six `bash -n` calls that stood here were a hand-patch around the lint
# gate's extension rule: none of these files ends in .sh, so none of them was
# syntax-checked anywhere else. ./scripts/lint.sh now reads its file set from
# scripts/list-shell-files.py, which selects on the shebang, and
# tests/test-lint-file-selection.sh proves a syntax error in each of them fails
# that gate.

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

# Every colour the Waybar stylesheet names must be one the theme integration
# actually defines. GTK's CSS parser errors on an undefined @name and drops the
# whole declaration, so a missing one is not a fallback: it is a logged parse
# error at every Waybar start and at every SIGUSR2 reload -- which the Fedora
# theme hook sends on every `theme` run -- and the widget renders in whatever it
# inherits. The two files are set-differenced rather than spot-checked, so a
# colour added to the stylesheet later cannot go undefined either.
waybar_style="$fedora_stow/waybar/.config/waybar/style.css"
theme_state_root="$test_root/theme-state"
mkdir -p "$theme_state_root"
env HOME="$theme_state_root" XDG_CONFIG_HOME="$theme_state_root/.config" \
  bash -c '
    set -euo pipefail
    source "$1/common/lib/common.sh"
    source "$1/platforms/fedora/lib/theme-desktop.sh"
    write_fedora_theme_state macchiato >/dev/null
  ' _ "$repo_root"

generated_css="$theme_state_root/.config/dotfiles/waybar-theme.css"
[[ -f "$generated_css" ]] || {
  printf 'The Fedora theme integration wrote no waybar-theme.css.\n' >&2
  exit 1
}

# `@define-color` and `@import` are CSS at-rules, not colour references.
defined_colours="$(grep -o '^@define-color [a-zA-Z0-9_-]*' "$generated_css" |
  awk '{ print $2 }' | sort -u)"
used_colours="$(grep -o '@[a-zA-Z0-9_-]*' "$waybar_style" |
  sed 's/^@//' | grep -Ev '^(import|define-color|media|keyframes|supports)$' |
  sort -u)"
undefined_colours="$(comm -23 <(printf '%s\n' "$used_colours") \
  <(printf '%s\n' "$defined_colours"))"
[[ -z "$undefined_colours" ]] || {
  printf 'Waybar stylesheet uses colours write_fedora_theme_state never defines: %s\n' \
    "$(printf '%s' "$undefined_colours" | tr '\n' ' ')" >&2
  exit 1
}
[[ -n "$used_colours" ]] || {
  printf 'No Waybar colour references were found; the check is not testing anything.\n' >&2
  exit 1
}

# Every flavour has to carry every colour: a palette that defines one only for
# some flavours would leave the others with an empty `@define-color name #;`.
for flavour in latte frappe macchiato mocha; do
  env HOME="$theme_state_root" XDG_CONFIG_HOME="$theme_state_root/.config" \
    bash -c '
      set -euo pipefail
      source "$1/common/lib/common.sh"
      source "$1/platforms/fedora/lib/theme-desktop.sh"
      write_fedora_theme_state "$2" >/dev/null
    ' _ "$repo_root" "$flavour"
  ! grep -Eq '^@define-color [a-zA-Z0-9_-]+ #;' "$generated_css" || {
    printf 'The %s palette leaves a Waybar colour empty.\n' "$flavour" >&2
    exit 1
  }
done
printf 'PASS: every Waybar colour reference is defined by the Fedora theme integration\n'

printf 'Sway configuration, 3x3 workspace navigation and display cycling tests passed.\n'
