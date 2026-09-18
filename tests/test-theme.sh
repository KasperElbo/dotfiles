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
  "$proc_root/4242" "$test_root/home/.local/share/wallpapers"
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
if [[ "$1" == "-t" && "$2" == "get_version" ]]; then
  [[ "${MOCK_SWAY_ACTIVE:-false}" == "true" ]] || exit 1
  exit 0
fi
printf 'swaymsg %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/lookandfeeltool" <<'EOF'
#!/usr/bin/env bash
printf 'lookandfeeltool %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/kwriteconfig6" <<'EOF'
#!/usr/bin/env bash
printf 'kwriteconfig6 %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/plasma-apply-colorscheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-colorscheme %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/plasma-apply-cursortheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-cursortheme %s\n' "$*" >>"$MOCK_LOG"
EOF
cat >"$mock_bin/plasma-apply-wallpaperimage" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-wallpaperimage %s\n' "$*" >>"$MOCK_LOG"
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

# The theme command consults the install lifecycle state to decide whether a
# capability's assets were ever installed, and that library uses awk; the rest
# is what write_theme_state has always needed.
for command in awk bash basename cat chmod dirname mkdir mktemp mv readlink; do
  ln -s "$(command -v "$command")" "$sandbox_bin/$command"
done

chmod +x "$mock_bin"/*

for flavour in latte frappe macchiato mocha; do
  ln -s \
    "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-$flavour.webp" \
    "$test_root/home/.local/share/wallpapers/catppuccin-$flavour.webp"
  ln -s \
    "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-$flavour-lock.webp" \
    "$test_root/home/.local/share/wallpapers/catppuccin-$flavour-lock.webp"
done

# This suite models a machine installed *with* KDE: the Catppuccin KDE global
# themes are present, so the Fedora hook may name their identifiers. The
# capability-awareness and failure-isolation cases (issue #148) live in
# tests/test-theme-hooks.sh.
for kde_theme in Catppuccin-Latte-Mauve Catppuccin-Frappe-Mauve \
  Catppuccin-Macchiato-Mauve Catppuccin-Mocha-Mauve; do
  mkdir -p "$test_root/home/.local/share/plasma/look-and-feel/$kde_theme"
done

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
XDG_STATE_HOME="$test_root/state" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
MOCK_SWAY_ACTIVE="false" \
  "$theme_command" mocha >/dev/null

grep -Fqx -- 'pkill -USR2 -x ghostty' "$mock_log"
if grep -Fq 'swaymsg reload' "$mock_log"; then
  printf 'A KDE-only session must not reload a Sway compositor.\n' >&2
  exit 1
fi
if grep -Fqx -- 'pkill -SIGUSR2 waybar' "$mock_log"; then
  printf 'A KDE-only session must not reload waybar.\n' >&2
  exit 1
fi
grep -Fqx 'theme = catppuccin-mocha.conf' \
  "$test_root/xdg/dotfiles/ghostty.conf"
grep -Fqx \
  "set \$wallpaper $test_root/home/.local/share/wallpapers/catppuccin-mocha.webp" \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fqx 'seat * xcursor_theme catppuccin-mocha-mauve-cursors 24' \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fqx 'lookandfeeltool --apply Catppuccin-Mocha-Mauve' "$mock_log"
grep -Fqx \
  'kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSizeAuto false' \
  "$mock_log"
grep -Fqx \
  "plasma-apply-wallpaperimage $test_root/home/.local/share/wallpapers/catppuccin-mocha.webp" \
  "$mock_log"
grep -Fqx \
  'kwriteconfig6 --file kscreenlockerrc --group Greeter --key WallpaperPlugin org.kde.image' \
  "$mock_log"
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image $test_root/home/.local/share/wallpapers/catppuccin-mocha-lock.webp" \
  "$mock_log"
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key PreviewImage $test_root/home/.local/share/wallpapers/catppuccin-mocha-lock.webp" \
  "$mock_log"
if grep -Fq 'qdbus ' "$mock_log"; then
  printf 'Default theme switching must not snapshot the KDE wallpaper.\n' >&2
  exit 1
fi

theme_line="$(grep -n '^lookandfeeltool ' "$mock_log" | cut -d: -f1)"
wallpaper_line="$(grep -n '^plasma-apply-wallpaperimage ' "$mock_log" | cut -d: -f1)"
if ((theme_line >= wallpaper_line)); then
  printf 'KDE wallpaper must be applied after the global theme.\n' >&2
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
MOCK_SWAY_ACTIVE="false" \
  "$theme_command" --preserve-wallpaper frappe >/dev/null

grep -Fqx 'theme = catppuccin-frappe.conf' \
  "$test_root/xdg/dotfiles/ghostty.conf"
grep -Fqx \
  "set \$wallpaper \"$test_root/home/Pictures/custom wallpaper.jpg\"" \
  "$test_root/xdg/dotfiles/sway-theme.conf"
grep -Fqx 'seat * xcursor_theme catppuccin-frappe-mauve-cursors 24' \
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

if grep -Fq 'swaymsg reload' "$mock_log"; then
  printf 'A KDE-only session must not reload a Sway compositor.\n' >&2
  exit 1
fi
grep -Fq 'file:///home/test/Pictures/custom.jpg' "$mock_log"
if grep -Fq 'plasma-apply-wallpaperimage ' "$mock_log"; then
  printf 'Preserved KDE wallpaper must not be replaced.\n' >&2
  exit 1
fi
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image $test_root/home/.local/share/wallpapers/catppuccin-frappe-lock.webp" \
  "$mock_log"
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key PreviewImage $test_root/home/.local/share/wallpapers/catppuccin-frappe-lock.webp" \
  "$mock_log"
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

# A machine with both the optional Sway profile and the base KDE tooling
# installed must not attempt KDE desktop integration while an actual Sway
# session is running: KDE's DBus-backed commands have nothing to talk to and
# would otherwise fail or misbehave.
: >"$mock_log"
HOME="$test_root/home" \
XDG_CONFIG_HOME="$test_root/xdg" \
XDG_DATA_HOME="$test_root/home/.local/share" \
XDG_STATE_HOME="$test_root/state" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
MOCK_SWAY_ACTIVE="true" \
  "$theme_command" mocha >/dev/null

if grep -Eq 'lookandfeeltool|kwriteconfig6|plasma-apply-|qdbus' "$mock_log"; then
  printf 'An active Sway session must not trigger KDE desktop integration.\n' >&2
  exit 1
fi
grep -Fqx 'swaymsg reload' "$mock_log"
grep -Fqx -- 'pkill -SIGUSR2 waybar' "$mock_log"
grep -Fqx 'seat * xcursor_theme catppuccin-mocha-mauve-cursors 24' \
  "$test_root/xdg/dotfiles/sway-theme.conf"

# --- The command chooses its interpreter before loading anything (#255) ------

# macOS ships Bash 3.2, where install-selection.sh's opening `declare -A` fails
# at source time with `declare: -A: invalid option`, before any of the command's
# own code runs. common/lib/modern-bash.sh chooses the interpreter first.
#
# This container has no Apple Bash to run the command under, so the selection
# library is exercised directly and the command is checked for calling it in the
# one place where the call helps -- ahead of every modern-Bash source.
bash32_root="$test_root/bash32"
mkdir -p "$bash32_root/bin"

# A `bash` that fails the version probe, which is what Apple's 3.2 does:
# `BASH_VERSINFO[0] > 4 || …` is false there. An absolute shebang, because this
# file goes on PATH and `#!/usr/bin/env bash` would find itself.
cat >"$bash32_root/bin/bash" <<EOF_OLD_BASH
#!$(command -v bash)
if [ "\${1:-}" = -c ]; then
  exit 1
fi
printf 'the 3.2 fixture was asked to run: %s\\n' "\$*" >&2
exit 97
EOF_OLD_BASH
chmod +x "$bash32_root/bin/bash"

modern_bash="$(command -v bash)"
library="$repo_root/common/lib/modern-bash.sh"

# probe <script>: the library sourced and driven in a child shell. `BASH` is
# assigned inside that shell rather than in its environment, because Bash sets
# BASH to the running interpreter at startup and would overwrite an exported
# value; the assignment is what lets these cases stand in for a login that
# reached the command through Apple's Bash.
probe() {
  "$modern_bash" -c "
    . '$library'
    $1
  " probe "${@:2}" 2>&1
}

output="$(probe "modern_bash_is_supported '$modern_bash' && echo supported")"
[[ "$output" == supported ]] ||
  { printf 'A modern Bash was not recognised: %s\n' "$output" >&2; exit 1; }
output="$(probe "modern_bash_is_supported '$bash32_root/bin/bash' || echo rejected")"
[[ "$output" == rejected ]] ||
  { printf 'The 3.2 fixture was accepted as supported: %s\n' "$output" >&2; exit 1; }
output="$(probe "modern_bash_is_supported '$test_root/no-such-bash' || echo rejected")"
[[ "$output" == rejected ]] ||
  { printf 'A missing interpreter was accepted: %s\n' "$output" >&2; exit 1; }
printf 'PASS: the version probe accepts 4.4+ and rejects 3.2 and absent\n'

# Re-exec: the fixture is what the shell believes it is running under, so the
# library must move to the supported one and hand it the original arguments.
argv_probe="$test_root/argv-probe"
cat >"$argv_probe" <<'EOF_ARGV'
#!/usr/bin/env bash
printf 'argv:'
printf ' [%s]' "$@"
printf '\n'
EOF_ARGV
chmod +x "$argv_probe"

output="$(probe "
  BASH='$bash32_root/bin/bash'
  DOTFILES_MODERN_BASH='$modern_bash'
  DOTFILES_BOOTSTRAP_TRACE=true
  modern_bash_reexec theme '$argv_probe' mocha --preserve-wallpaper
")"
grep -Fq 're-executing with' <<<"$output" ||
  { printf 'No re-exec happened under an unsupported Bash:\n%s\n' "$output" >&2; exit 1; }
grep -Fq 'argv: [mocha] [--preserve-wallpaper]' <<<"$output" ||
  { printf 'Arguments did not survive the re-exec:\n%s\n' "$output" >&2; exit 1; }
printf 'PASS: an unsupported Bash re-execs, and every argument survives\n'

# An already-supported Bash must return rather than re-exec, which is what keeps
# Linux behaviour unchanged: no second process, no trace line.
output="$(probe "
  DOTFILES_BOOTSTRAP_TRACE=true
  modern_bash_reexec theme '$argv_probe' mocha && echo continued
")"
[[ "$output" == continued ]] ||
  { printf 'A supported Bash did not continue in place: %s\n' "$output" >&2; exit 1; }
printf 'PASS: a supported Bash continues in place, creating no new process\n'

# With nothing supported to move to, the caller gets the cause and the fix.
output="$(probe "
  BASH='$bash32_root/bin/bash'
  DOTFILES_MODERN_BASH='$bash32_root/bin/bash'
  PATH='$bash32_root/bin'
  modern_bash_reexec theme '$argv_probe' mocha || echo refused
")"
grep -Fq 'theme requires Bash 4.4 or newer' <<<"$output" ||
  { printf 'A missing modern Bash produced no diagnostic:\n%s\n' "$output" >&2; exit 1; }
grep -Fq './install.sh --platform macos' <<<"$output" ||
  { printf 'The diagnostic does not name the remediation:\n%s\n' "$output" >&2; exit 1; }
grep -Fq refused <<<"$output" ||
  { printf 'The caller was not told to refuse:\n%s\n' "$output" >&2; exit 1; }
if grep -Fq 'declare' <<<"$output"; then
  printf 'A declare error reached the user:\n%s\n' "$output" >&2
  exit 1
fi
printf 'PASS: no supported Bash gives a focused diagnostic, not a declare error\n'

# The guard only helps if it runs before the first modern-Bash source, so that
# ordering is asserted rather than left to the next edit of the file.
theme_command="$repo_root/bin/.local/bin/theme"
guard_line="$(grep -n '^modern_bash_reexec ' "$theme_command" | head -n 1 | cut -d: -f1)"
first_modern_source="$(grep -n '^source "\$repo_root/common/lib/' "$theme_command" | head -n 1 | cut -d: -f1)"
[[ -n "$guard_line" && -n "$first_modern_source" ]] ||
  { printf 'The theme command no longer has both a guard and a library source\n' >&2; exit 1; }
((guard_line < first_modern_source)) ||
  { printf 'The modern-Bash guard runs after a library source (%s vs %s)\n' \
      "$guard_line" "$first_modern_source" >&2; exit 1; }
printf 'PASS: the guard runs before the first modern-Bash library source\n'

# The dialect claim is checkable, so it is checked: nothing above the guard, and
# nothing in the library it sources, may use syntax Apple's Bash lacks -- that
# code would fail before the guard could help.
# `[[ ]]` and `(( ))` are 3.2 syntax and are not listed; what 3.2 lacks is
# associative arrays, mapfile and case-converting expansions. Comments are
# stripped first, so prose naming a construct is not mistaken for using it.
check_bash32_dialect() {
  local label="$1" text="$2" pattern
  text="$(sed -e 's/^[[:space:]]*#.*$//' <<<"$text")"
  for pattern in 'declare -[Aa]' 'local -[Aa]' '\bmapfile\b' '\breadarray\b' \
    '\$\{[A-Za-z_][A-Za-z_0-9]*,,?\}' '\$\{[A-Za-z_][A-Za-z_0-9]*\^\^?\}'; do
    if grep -Eq -- "$pattern" <<<"$text"; then
      printf '%s uses %s, which Apple Bash 3.2 does not have\n' "$label" "$pattern" >&2
      exit 1
    fi
  done
}
check_bash32_dialect 'common/lib/modern-bash.sh' "$(cat "$library")"
check_bash32_dialect 'the theme command above its modern-Bash guard' \
  "$(sed -n "1,${guard_line}p" "$theme_command")"
printf 'PASS: the guard and its library stay inside the Bash 3.2 dialect\n'

printf 'Theme parsing and desktop wallpaper preservation tests passed.\n'
