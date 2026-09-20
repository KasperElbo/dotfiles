#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
install_log="$test_root/install.log"
side_effect_log="$test_root/side-effects.log"
command_log="$test_root/commands.log"
home="$test_root/home"
mkdir -p "$mock_bin" "$home/.local/share/wallpapers"
: >"$install_log"
: >"$side_effect_log"
: >"$command_log"

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -q ]]; then
  for present in $RPM_PRESENT; do
    [[ "$2" == "$present" ]] && exit 0
  done
  exit 1
fi
exit 0
EOF

test_stub_init "$test_root"
test_stub_install "$test_root" dnf
test_stub_install "$test_root" git
test_stub_install "$test_root" sudo
for package in kio-extras wget; do
  test_stub_allow "$test_root" dnf install -y "$package"
  test_stub_allow "$test_root" sudo dnf install -y "$package"
done
# The pinned tag is read from the installer rather than repeated here, so
# bumping the pin cannot leave this stub allowing the previous tag.
kde_pin="$(sed -n 's/^version="\(v[0-9][0-9.]*\)"$/\1/p' \
  "$repo_root/platforms/fedora/scripts/install-kde-theme.sh")"
[[ -n "$kde_pin" ]] || _test_die 'could not read the Catppuccin KDE pin'
test_stub_allow "$test_root" git clone --branch "$kde_pin" --depth 1 \
  https://github.com/catppuccin/kde.git \
  "$test_root/cache/dotfiles/catppuccin-kde"

cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF

# A real `dnf install wget` puts wget on PATH, and the fixture installer below
# refuses to run without it, exactly as the pinned upstream one does. So this
# handler has to put it there too: without it the suite would assert that a
# command was logged and never that the install it stands for had any effect.
# TEST_KDE_DNF_INERT switches that off, for the negative control at the end.
cat >"$test_root/handlers/dnf" <<'EOF'
#!/usr/bin/env bash
[[ -z "${TEST_KDE_DNF_INERT:-}" ]] || exit 0
for argument in "$@"; do
  [[ "$argument" == wget ]] || continue
  printf '#!/usr/bin/env sh\nexit 0\n' >"$TEST_STUB_ROOT/bin/wget"
  chmod +x "$TEST_STUB_ROOT/bin/wget"
done
EOF

cat >"$test_root/handlers/git" <<'EOF'
#!/usr/bin/env bash
destination="${*: -1}"
mkdir -p "$destination"
cat >"$destination/install.sh" <<'INSTALLER'
#!/usr/bin/env sh
# The pinned upstream installer checks its dependencies before installing
# anything, and a missing wget stops it dead -- which is how the scheduled
# real installation failed. Reproduce that, so dropping the wget install
# fails this suite instead of only the next Fedora run.
#
# It insists on the wget the installer put in the stub directory rather than
# on any wget: the suite runs with the host PATH appended, so accepting
# whatever `command -v` finds would pass on any machine that happens to have
# one and prove nothing here.
case "$(command -v wget 2>/dev/null)" in
"$EXPECTED_WGET") ;;
*)
  printf "Error: Dependency 'wget' is not met.\n" >&2
  exit 1
  ;;
esac
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

chmod +x "$mock_bin"/* "$test_root/handlers"/*

install_environment=(
  env
  "HOME=$home"
  "XDG_CACHE_HOME=$test_root/cache"
  "INSTALL_LOG=$install_log"
  "SIDE_EFFECT_LOG=$side_effect_log"
  "COMMAND_LOG=$command_log"
  "EXPECTED_WGET=$mock_bin/wget"
  "PATH=$mock_bin:$PATH"
)

install_kde_themes() {
  RPM_PRESENT="${RPM_PRESENT:-}" "${install_environment[@]}" \
    "$repo_root/platforms/fedora/scripts/install-kde-theme.sh" >/dev/null
}
[[ ! -e "$mock_bin/wget" ]] ||
  _test_die 'wget is already in the stub directory, so installing it proves nothing'
RPM_PRESENT="" install_kde_themes
grep -Fq 'sudo dnf install -y kio-extras' "$command_log"
printf 'PASS: missing kio-extras is installed for Dolphin sftp:// support\n'
grep -Fq 'sudo dnf install -y wget' "$command_log"
printf 'PASS: missing wget is installed before the upstream installer runs\n'

: >"$command_log"
RPM_PRESENT="kio-extras wget" install_kde_themes
if [[ -s "$command_log" ]]; then
  printf 'A package was reinstalled even though it was already present:\n' >&2
  cat "$command_log" >&2
  exit 1
fi
printf 'PASS: already-present packages are reused, not reinstalled\n'

for flavour in 1 2 3 4; do
  [[ "$(grep -Fxc "$flavour 4 2 auto" "$install_log")" == 2 ]]
done

if [[ -s "$side_effect_log" ]]; then
  printf 'The upstream KDE installer changed the live desktop.\n' >&2
  cat "$side_effect_log" >&2
  exit 1
fi

# The negative control for the two assertions above: with a dnf that installs
# nothing, the fixture upstream installer has to fail the way the real one did
# on the scheduled run. This is what an install-kde-theme.sh that stopped
# installing wget would look like, so if this passes, those assertions prove
# nothing.
rm -f "$mock_bin/wget"
if negative_output="$(TEST_KDE_DNF_INERT=1 RPM_PRESENT="" install_kde_themes 2>&1)"; then
  _test_die 'the upstream installer ran without wget, so a missing one cannot fail this suite'
fi
unset TEST_KDE_DNF_INERT
assert_contains "$negative_output" "Dependency 'wget' is not met."
printf 'PASS: an upstream installer that cannot find wget fails the install\n'

ln -s \
  "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-macchiato.webp" \
  "$home/.local/share/wallpapers/catppuccin-macchiato.webp"
ln -s \
  "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-macchiato-lock.webp" \
  "$home/.local/share/wallpapers/catppuccin-macchiato-lock.webp"

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
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key Image $home/.local/share/wallpapers/catppuccin-macchiato-lock.webp" \
  "$side_effect_log"
grep -Fqx \
  "kwriteconfig6 --file kscreenlockerrc --group Greeter --group Wallpaper --group org.kde.image --group General --key PreviewImage $home/.local/share/wallpapers/catppuccin-macchiato-lock.webp" \
  "$side_effect_log"

printf 'KDE theme installation and final flavour tests passed.\n'
