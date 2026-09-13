#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
font_dir="$data/fonts/HackNerdFont/3.4.0"
bat_theme_dir="$config/bat/themes"
mkdir -p "$mock_bin" "$font_dir" "$bat_theme_dir"
printf 'ID=parrot\n' >"$test_root/os-release"
printf 'font fixture\n' >"$font_dir/HackNerdFontMono-Regular.ttf"
for flavour in Latte Frappe Macchiato Mocha; do
  printf '%s fixture\n' "$flavour" >"$bat_theme_dir/Catppuccin $flavour.tmTheme"
done

cat >"$mock_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --check ]]; then cat >/dev/null; exit 0; fi
case "$1" in
  *Latte*) hash=a2ddb65bfcf7328802ee4770d1e34ef4093a20fd5c300be3138c99f8a45ed5cb ;;
  *Frappe*) hash=3446d8a3cfb9eb559bc65a3894e6ae8f3579030fac6130c4f96ff524f3e2784f ;;
  *Macchiato*) hash=110090f655b970e569d82fb3780c161769b59ba234c290d0039c1e8c49bb5a06 ;;
  *Mocha*) hash=395566f08ceb301b936b91c077690ef94f7aeb651b121553f201c99c2bd4aa77 ;;
  *) hash=fixture ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF
cat >"$mock_bin/fc-cache" <<'EOF'
#!/usr/bin/env bash
printf 'fc-cache %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/bat" <<'EOF'
#!/usr/bin/env bash
printf 'bat %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/kwriteconfig6" <<'EOF'
#!/usr/bin/env bash
printf 'kwriteconfig6 %s\n' "$*" >>"$COMMAND_LOG"
mkdir -p "$XDG_CONFIG_HOME"
printf '[Desktop Entry]\nDefaultProfile=Dotfiles-Parrot-CTF.profile\n' >"$XDG_CONFIG_HOME/konsolerc"
EOF
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'Unexpected download during idempotent terminal install.\n' >&2
exit 1
EOF
chmod +x "$mock_bin"/*

environment=(
  env "HOME=$home" "XDG_CONFIG_HOME=$config" "XDG_DATA_HOME=$data"
  "PATH=$mock_bin:/usr/bin:/bin" "COMMAND_LOG=$command_log"
  "OS_RELEASE_FILE=$test_root/os-release"
)

"${environment[@]}" "$repo_root/platforms/parrot-ctf/scripts/install-terminal.sh" >/dev/null
profile="$data/konsole/Dotfiles-Parrot-CTF.profile"
grep -Fxq 'Font=Hack Nerd Font Mono,10,-1,5,50,0,0,0,0,0' "$profile"
if grep -Eq '^Command=' "$profile"; then
  printf 'Konsole profile contains an unnecessary shell override.\n' >&2
  exit 1
fi
grep -Fq 'DefaultProfile Dotfiles-Parrot-CTF.profile' "$command_log"
first_profile="$(sha256sum "$profile")"
"${environment[@]}" "$repo_root/platforms/parrot-ctf/scripts/install-terminal.sh" >/dev/null
[[ "$(sha256sum "$profile")" == "$first_profile" ]]

grep -Fq 'font_version="3.4.0"' \
  "$repo_root/platforms/parrot-ctf/scripts/install-terminal.sh"
grep -Fq 'bat_theme_commit="6810349b28055dce54076712fc05fc68da4b8ec0"' \
  "$repo_root/platforms/parrot-ctf/scripts/install-terminal.sh"

printf 'Parrot Konsole, Nerd Font, and bat theme tests passed.\n'
