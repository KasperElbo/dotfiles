#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
config="$repo_root/sway/.config/sway/config"
waybar="$repo_root/waybar/.config/waybar/config.jsonc"
grid="$repo_root/sway/.local/bin/sway-workspace-grid"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

command -v stow >/dev/null 2>&1 || {
  printf 'GNU Stow is required for Sway configuration tests.\n' >&2
  exit 1
}

# The dollar-prefixed strings below are literal Sway variables.
# shellcheck disable=SC2016
for shortcut in \
  'bindsym $mod+Return exec ghostty' \
  'bindsym $mod+p exec fuzzel' \
  'bindsym $mod+Shift+c kill' \
  'bindsym $mod+f fullscreen toggle' \
  'bindsym $mod+Ctrl+$left exec sway-workspace-grid left'; do
  grep -Fq "$shortcut" "$config"
done

grep -Fq "timeout 600" "$config"
grep -Fq "timeout 900" "$config"
if grep -Ev '^[[:space:]]*#' "$config" | grep -Eq 'suspend|hibernate'; then
  printf 'Sway config must not suspend or hibernate automatically.\n' >&2
  exit 1
fi

for module in \
  sway/workspaces sway/window custom/power-profile network bluetooth \
  pulseaudio battery clock; do
  grep -Fq "\"$module\"" "$waybar"
done

stow_home="$test_root/home"
mkdir -p "$stow_home"
HOME="$stow_home" \
  XDG_CONFIG_HOME="$stow_home/.config" \
  XDG_DATA_HOME="$stow_home/.local/share" \
  "$repo_root/scripts/setup-local.sh" macchiato --sway >/dev/null
HOME="$stow_home" \
  XDG_CONFIG_HOME="$stow_home/.config" \
  XDG_DATA_HOME="$stow_home/.local/share" \
  "$repo_root/scripts/stow.sh" --sway >/dev/null

[[ -L "$stow_home/.config/sway/config" ]]
[[ -L "$stow_home/.config/waybar/config.jsonc" ]]
[[ -L "$stow_home/.local/bin/sway-workspace-grid" ]]
[[ -f "$stow_home/.config/sway/local.conf" ]]
[[ ! -L "$stow_home/.config/sway/local.conf" ]]

mkdir -p "$test_root/bin" "$test_root/state"
cat >"$test_root/bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-t get_workspaces -r' ]]; then
  printf '[{"focused":true,"num":%s}]\n' "$CURRENT_WORKSPACE"
else
  printf '%s\n' "$*" >"$GRID_RESULT"
fi
EOF
chmod +x "$test_root/bin/swaymsg"

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
  wallpaper="$repo_root/sway/.local/share/wallpapers/catppuccin-$flavour.webp"
  [[ -s "$wallpaper" ]]
done

bash -n "$grid"
bash -n "$repo_root/sway/.local/bin/sway-screenshot"
bash -n "$repo_root/sway/.local/bin/power-profile-status"

printf 'Sway configuration and 3x3 workspace navigation tests passed.\n'
