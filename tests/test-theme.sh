#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
sandbox_bin="$test_root/sandbox-bin"
mock_log="$test_root/mock.log"
proc_root="$test_root/proc"
mkdir -p \
  "$mock_bin" "$sandbox_bin" "$test_root/home" "$test_root/xdg" \
  "$proc_root/4242"
mkdir -p "$test_root/xdg/dotfiles/theme-hooks.d"
ln -s \
  "$repo_root/platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh" \
  "$test_root/xdg/dotfiles/theme-hooks.d/fedora.sh"

cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--user is-active --quiet app-com.mitchellh.ghostty.service" ]]; then
  exit 1
fi
exit 0
EOF
cat >"$mock_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-x ghostty" ]]; then
  exit 0
fi
if [[ "$*" == *"-x swaybg" && "${MOCK_SWAYBG_RUNNING:-false}" == "true" ]]; then
  printf '4242\n'
  exit 0
fi
exit 1
EOF
cat >"$mock_bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$mock_bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
printf 'swaymsg %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/lookandfeeltool" <<'EOF'
#!/usr/bin/env bash
printf 'lookandfeeltool %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/plasma-apply-colorscheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-colorscheme %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/plasma-apply-cursortheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-cursortheme %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/qdbus6" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"var result = []"* ]]; then
  printf 'qdbus capture\n' >>"$MOCK_LOG"
  printf '%s\n' '[{"id":7,"plugin":"org.kde.image","config":{"values":{},"groups":{"General":{"values":{"Image":"file:///home/test/Pictures/custom.jpg"},"groups":{}}}}}]'
else
  printf 'qdbus restore %s\n' "$*" >>"$MOCK_LOG"
fi
EOF

for command in bash basename cat chmod dirname mkdir mktemp mv readlink; do
  ln -s "$(command -v "$command")" "$sandbox_bin/$command"
done

chmod +x "$mock_bin"/*

theme_command="$repo_root/bin/.local/bin/theme"

"$theme_command" --help | grep -Fq -- '--preserve-wallpaper'

if "$theme_command" mocha --unknown >"$test_root/invalid.out" 2>&1; then
  printf 'Unknown theme flags must fail.\n' >&2
  exit 1
fi
grep -Fq 'Unknown option: --unknown' "$test_root/invalid.out"
grep -Fq 'Usage: theme' "$test_root/invalid.out"

if "$theme_command" --preserve-wallpaper >"$test_root/missing.out" 2>&1; then
  printf 'A missing flavour must fail.\n' >&2
  exit 1
fi
grep -Fq 'Usage: theme' "$test_root/missing.out"

HOME="$test_root/home" \
XDG_CONFIG_HOME="$test_root/xdg" \
XDG_DATA_HOME="$test_root/home/.local/share" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
  "$theme_command" mocha >/dev/null

grep -Fqx -- 'pkill -USR2 -x ghostty' "$mock_log"
grep -Fqx 'theme = catppuccin-mocha.conf' \
  "$test_root/xdg/dotfiles/ghostty.conf"
grep -Fqx \
  "set \$wallpaper $test_root/home/.local/share/wallpapers/catppuccin-mocha.webp" \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fqx 'lookandfeeltool --apply Catppuccin-Mocha-Mauve' "$mock_log"
if grep -Fq 'qdbus ' "$mock_log"; then
  printf 'Default theme switching must not snapshot the KDE wallpaper.\n' >&2
  exit 1
fi

: >"$mock_log"
printf '%s\0' \
  /usr/bin/swaybg -o '*' -i \
  "$test_root/home/Pictures/custom wallpaper.jpg" -m fill \
  >"$proc_root/4242/cmdline"

HOME="$test_root/home" \
XDG_CONFIG_HOME="$test_root/xdg" \
XDG_DATA_HOME="$test_root/home/.local/share" \
DOTFILES_PROC_ROOT="$proc_root" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
MOCK_SWAYBG_RUNNING="true" \
  "$theme_command" --preserve-wallpaper frappe >/dev/null

grep -Fqx 'theme = catppuccin-frappe.conf' \
  "$test_root/xdg/dotfiles/ghostty.conf"
grep -Fqx \
  "set \$wallpaper \"$test_root/home/Pictures/custom wallpaper.jpg\"" \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fq 'catppuccin-frappe-lock.webp' \
  "$test_root/xdg/dotfiles/swaylock.conf"

capture_line="$(grep -n '^qdbus capture$' "$mock_log" | cut -d: -f1)"
theme_line="$(grep -n '^lookandfeeltool ' "$mock_log" | cut -d: -f1)"
restore_line="$(grep -n '^qdbus restore ' "$mock_log" | cut -d: -f1)"
if [[ -z "$capture_line" || -z "$theme_line" || -z "$restore_line" ]] ||
  ((capture_line >= theme_line || theme_line >= restore_line)); then
  printf 'KDE wallpaper must be captured and restored around global theming.\n' >&2
  exit 1
fi

grep -Fqx 'swaymsg reload' "$mock_log"
grep -Fq 'file:///home/test/Pictures/custom.jpg' "$mock_log"
grep -Fqx 'plasma-apply-colorscheme CatppuccinFrappeMauve' "$mock_log"
grep -Fqx 'plasma-apply-cursortheme catppuccin-frappe-mauve-cursors' \
  "$mock_log"

# Outside a running Sway session, preserve the previously captured wallpaper
# in generated state rather than replacing it with the next flavour's default.
HOME="$test_root/home" \
XDG_CONFIG_HOME="$test_root/xdg" \
XDG_DATA_HOME="$test_root/home/.local/share" \
DOTFILES_PROC_ROOT="$proc_root" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
MOCK_SWAYBG_RUNNING="false" \
  "$theme_command" mocha --preserve-wallpaper >/dev/null

grep -Fqx \
  "set \$wallpaper \"$test_root/home/Pictures/custom wallpaper.jpg\"" \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fq 'catppuccin-mocha-lock.webp' \
  "$test_root/xdg/dotfiles/swaylock.conf"

printf 'Theme parsing and desktop wallpaper preservation tests passed.\n'
