#!/usr/bin/env bash
# Guards docs/keybindings.md and docs/cheatsheets/*.tex against silently
# drifting from the tracked Sway, Waybar, and AeroSpace configuration they
# describe (issue #72). This intentionally checks only the load-bearing
# bindings called out in docs/cheatsheets/README.md, not every binding in
# either config -- it is not a LaTeX compile check, so it does not require a
# LaTeX toolchain to run as part of ./scripts/test.sh.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sway_config="$repo_root/platforms/fedora/stow/sway/.config/sway/config"
waybar_config="$repo_root/platforms/fedora/stow/waybar/.config/waybar/config.jsonc"
aerospace_config="$repo_root/platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml"
kde_readme_section="$repo_root/README.md"
keybindings_doc="$repo_root/docs/keybindings.md"
cheatsheets_dir="$repo_root/docs/cheatsheets"
sway_tex="$cheatsheets_dir/fedora-sway.tex"
kde_tex="$cheatsheets_dir/fedora-kde.tex"
wsl_tex="$cheatsheets_dir/fedora-wsl.tex"
macos_tex="$cheatsheets_dir/macos.tex"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_in() {
  local file="$1" needle="$2" label="$3"
  grep -Fq "$needle" "$file" || fail "$label: expected to find '$needle' in $file"
}

# --- Sway config still has the bindings the Sway cheat sheet documents ---
# shellcheck disable=SC2016
for binding in \
  'bindsym $mod+Return exec ghostty' \
  'bindsym $mod+p exec fuzzel' \
  'bindsym $mod+$left focus left' \
  'bindsym $mod+Shift+$left move left' \
  'bindsym $mod+1 workspace number $ws1' \
  'bindsym $mod+Shift+1 move container to workspace number $ws1' \
  'bindsym $mod+Ctrl+$left exec sway-workspace-grid left' \
  'bindsym $mod+$alt+k input type:keyboard xkb_switch_layout next' \
  'bindsym $mod+Shift+x exec swaylock' \
  'bindsym $mod+Shift+r reload' \
  'bindsym $mod+r mode "resize"' \
  'bindsym Shift+Print exec sway-screenshot output' \
  'bindsym $mod+Shift+v exec cliphist list'; do
  require_in "$sway_config" "$binding" "Sway config"
done

# --- The Sway cheat sheet actually documents those same bindings ---
for phrase in \
  'Super+Enter' 'Open Ghostty' \
  'Super+P' 'Fuzzel' \
  'Super+H/J/K/L' \
  'Super+Shift+H/J/K/L' \
  'Super+1..9' \
  'Super+Shift+1..9' \
  'Super+Ctrl+H/J/K/L' \
  'Super+Alt+K' \
  'Switch US/Danish keyboard layout' \
  'Lock session' \
  'Reload Sway config' \
  'Enter resize mode' \
  'Save full output' \
  'Clipboard history'; do
  require_in "$sway_tex" "$phrase" "Sway cheat sheet"
done

# --- Waybar's keyboard-layout indicator matches what the Sway sheet claims ---
require_in "$waybar_config" '"sway/language"' "Waybar config"
require_in "$waybar_config" '"format": "{short}"' "Waybar config"
require_in "$waybar_config" \
  '"on-click": "swaymsg input type:keyboard xkb_switch_layout next"' \
  "Waybar config"
require_in "$sway_tex" 'sway/language' "Sway cheat sheet"
require_in "$sway_tex" 'clicked' "Sway cheat sheet"

# --- AeroSpace config still has the bindings the macOS cheat sheet documents ---
for binding in \
  "ctrl-alt-enter = 'exec-and-forget open -na Ghostty'" \
  "ctrl-alt-h = 'focus --boundaries all-monitors-outer-frame left'" \
  "ctrl-alt-shift-h = 'move --boundaries all-monitors-outer-frame left'" \
  "ctrl-alt-1 = 'workspace 1'" \
  "ctrl-alt-shift-1 = 'move-node-to-workspace 1'" \
  "ctrl-alt-cmd-h = 'exec-and-forget ~/.local/bin/aerospace-workspace-grid left'" \
  "ctrl-alt-shift-r = 'reload-config'" \
  "ctrl-alt-r = 'mode resize'" \
  "ctrl-alt-shift-c = 'close'"; do
  require_in "$aerospace_config" "$binding" "AeroSpace config"
done

for phrase in \
  'Control+Option+Enter' \
  'Control+Option+H/J/K/L' \
  'Ctrl+Opt+Shift+H/J/K/L' \
  'Control+Option+1..9' \
  'Ctrl+Opt+Shift+1..9' \
  'Ctrl+Opt+Cmd+H/J/K/L' \
  'Reload AeroSpace config' \
  'Enter resize mode' \
  'Close focused window'; do
  require_in "$macos_tex" "$phrase" "macOS cheat sheet"
done

# --- The KDE cheat sheet does not claim Plasma's own default as a dotfiles binding ---
require_in "$kde_tex" 'Meta+Alt+K' "Fedora KDE cheat sheet"
require_in "$kde_tex" "Plasma 6's own default" "Fedora KDE cheat sheet"
grep -Eq 'not a dotfiles binding' "$kde_tex" ||
  fail "Fedora KDE cheat sheet: must not imply Meta+Alt+K is a dotfiles binding"

# --- The Fedora WSL cheat sheet omits the layout toggle (Windows owns input) ---
if grep -Fq 'Meta+Alt+K' "$wsl_tex" || grep -Fq 'Super+Alt+K' "$wsl_tex"; then
  fail "Fedora WSL cheat sheet: must not include the KDE/Sway keyboard-layout shortcut"
fi
require_in "$wsl_tex" 'wsl-open' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'wsl-copy' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'wsl-paste' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'enabled=true' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'appendWindowsPath=false' "Fedora WSL cheat sheet"

# --- README's own layout-switch documentation (source for the KDE sheet) ---
require_in "$kde_readme_section" 'Meta+Alt+K' "README.md"

# --- Discovery mechanisms stay prominent rather than static tables drifting ---
for phrase in \
  'ghostty +list-keybinds --default' \
  'WhichKey' \
  'Lazygit' \
  '<prefix> ?' \
  'System Settings'; do
  grep -Fq "$phrase" "$keybindings_doc" ||
    fail "docs/keybindings.md: expected discovery reference '$phrase'"
done

# --- Every cheat sheet input file referenced actually exists ---
for f in "$sway_tex" "$kde_tex" "$wsl_tex" "$macos_tex" \
  "$cheatsheets_dir/common-workflow.tex" "$cheatsheets_dir/cheatsheet.sty" \
  "$cheatsheets_dir/generate.sh"; do
  [[ -f "$f" ]] || fail "missing tracked file: $f"
done
[[ -x "$cheatsheets_dir/generate.sh" ]] ||
  fail "$cheatsheets_dir/generate.sh must be executable"

printf 'Cheat sheet / keybinding documentation accuracy checks passed.\n'
