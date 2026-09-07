#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
install_log="$test_root/install.log"
side_effect_log="$test_root/side-effects.log"
home="$test_root/home"
mkdir -p "$mock_bin" "$home/.local/share/wallpapers"
: >"$install_log"
: >"$side_effect_log"

cat >"$mock_bin/git" <<'EOF'
#!/usr/bin/env bash
destination="${*: -1}"
mkdir -p "$destination"
cat >"$destination/install.sh" <<'INSTALLER'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$INSTALL_LOG"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSizeAuto false
plasma-apply-lookandfeel -a "Catppuccin-$1"
INSTALLER
chmod +x "$destination/install.sh"
EOF

cat >"$mock_bin/plasma-apply-lookandfeel" <<'EOF'
#!/usr/bin/env bash
printf 'upstream look-and-feel %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/kwriteconfig6" <<'EOF'
#!/usr/bin/env bash
printf 'kwriteconfig6 %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/lookandfeeltool" <<'EOF'
#!/usr/bin/env bash
printf 'lookandfeeltool %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/plasma-apply-colorscheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-colorscheme %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/plasma-apply-cursortheme" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-cursortheme %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/plasma-apply-wallpaperimage" <<'EOF'
#!/usr/bin/env bash
printf 'plasma-apply-wallpaperimage %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

cat >"$mock_bin/qdbus6" <<'EOF'
#!/usr/bin/env bash
printf 'qdbus6 %s\n' "$*" >>"$SIDE_EFFECT_LOG"
EOF

chmod +x "$mock_bin"/*

install_environment=(
  env
  "HOME=$home"
  "XDG_CACHE_HOME=$test_root/cache"
  "INSTALL_LOG=$install_log"
  "SIDE_EFFECT_LOG=$side_effect_log"
  "PATH=$mock_bin:$PATH"
)

install_kde_themes() {
  "${install_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/install-kde-theme.sh" >/dev/null
}
install_kde_themes
install_kde_themes

for flavour in 1 2 3 4; do
  [[ "$(grep -Fxc "$flavour 4 2 auto" "$install_log")" == 2 ]]
done

if [[ -s "$side_effect_log" ]]; then
  printf 'The upstream KDE installer changed the live desktop.\n' >&2
  cat "$side_effect_log" >&2
  exit 1
fi

ln -s \
  "$repo_root/platforms/fedora/stow/theme-assets/.local/share/wallpapers/catppuccin-macchiato.webp" \
  "$home/.local/share/wallpapers/catppuccin-macchiato.webp"

HOME="$home" \
PATH="$mock_bin:$PATH" \
SIDE_EFFECT_LOG="$side_effect_log" \
  "$repo_root/platforms/fedora/scripts/apply-kde-theme.sh" macchiato >/dev/null

[[ "$(grep -Fxc 'lookandfeeltool --apply Catppuccin-Macchiato-Mauve' \
  "$side_effect_log")" == 1 ]]
grep -Fqx 'plasma-apply-colorscheme CatppuccinMacchiatoMauve' \
  "$side_effect_log"
grep -Fqx 'plasma-apply-cursortheme catppuccin-macchiato-mauve-cursors' \
  "$side_effect_log"
grep -Fqx \
  "plasma-apply-wallpaperimage $home/.local/share/wallpapers/catppuccin-macchiato.webp" \
  "$side_effect_log"

printf 'KDE theme installation and final flavour tests passed.\n'
