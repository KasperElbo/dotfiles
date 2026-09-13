#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

require_parrot

font_version="3.4.0"
font_sha256="1d00a1435638084174516975840854368a45ac30bb0bad2c0c49db713b5925f0"
font_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${font_version}/Hack.tar.xz"
font_dir="$XDG_DATA_HOME/fonts/HackNerdFont/$font_version"
font_file="$font_dir/HackNerdFontMono-Regular.ttf"

if [[ ! -f "$font_file" ]]; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "$work_dir"' EXIT
  archive="$work_dir/Hack.tar.xz"
  extracted="$work_dir/extracted"
  mkdir -p "$extracted" "$font_dir"

  info "Downloading Hack Nerd Font $font_version"
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    "$font_url" --output "$archive"
  printf '%s  %s\n' "$font_sha256" "$archive" | sha256sum --check --status ||
    die "Hack Nerd Font archive checksum mismatch"
  tar --extract --xz --no-same-owner --file "$archive" --directory "$extracted" \
    --wildcards 'HackNerdFontMono-*.ttf'
  install -m 0644 "$extracted"/HackNerdFontMono-*.ttf "$font_dir/"
else
  info "Hack Nerd Font $font_version is already installed"
fi

fc-cache --force "$font_dir" >/dev/null

# Parrot's bat package does not ship the Catppuccin syntaxes referenced by the
# shared BAT_THEME and Delta configuration. Install the upstream files at one
# reviewed commit so Git paging never falls back with a misleading warning.
bat_theme_commit="6810349b28055dce54076712fc05fc68da4b8ec0"
bat_theme_dir="$XDG_CONFIG_HOME/bat/themes"
mkdir -p "$bat_theme_dir"
declare -A bat_theme_hashes=(
  [Latte]="a2ddb65bfcf7328802ee4770d1e34ef4093a20fd5c300be3138c99f8a45ed5cb"
  [Frappe]="3446d8a3cfb9eb559bc65a3894e6ae8f3579030fac6130c4f96ff524f3e2784f"
  [Macchiato]="110090f655b970e569d82fb3780c161769b59ba234c290d0039c1e8c49bb5a06"
  [Mocha]="395566f08ceb301b936b91c077690ef94f7aeb651b121553f201c99c2bd4aa77"
)
for flavour in Latte Frappe Macchiato Mocha; do
  theme_file="$bat_theme_dir/Catppuccin $flavour.tmTheme"
  expected_hash="${bat_theme_hashes[$flavour]}"
  if [[ -f "$theme_file" ]] &&
    [[ "$(sha256sum "$theme_file" | cut -d' ' -f1)" == "$expected_hash" ]]; then
    continue
  fi

  temporary_theme="$(mktemp "$bat_theme_dir/.catppuccin.XXXXXX")"
  encoded_name="Catppuccin%20${flavour}.tmTheme"
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/catppuccin/bat/${bat_theme_commit}/themes/${encoded_name}" \
    --output "$temporary_theme"
  printf '%s  %s\n' "$expected_hash" "$temporary_theme" |
    sha256sum --check --status || die "Catppuccin $flavour bat theme checksum mismatch"
  chmod 0644 "$temporary_theme"
  mv -- "$temporary_theme" "$theme_file"
done

# Debian/Parrot packages bat as `batcat`; the supported portable `bat` command
# is the stowed shim installed immediately before this script runs. The current
# installer process has not started a fresh login shell yet, so ~/.local/bin
# may not be on PATH. Invoke the managed shim explicitly instead of depending
# on ambient install-time PATH state.
bat_command="$HOME/.local/bin/bat"
[[ -x "$bat_command" ]] || die "Parrot bat shim is missing after Stow: $bat_command"
"$bat_command" cache --build >/dev/null

konsole_dir="$XDG_DATA_HOME/konsole"
konsole_profile="$konsole_dir/Dotfiles-Parrot-CTF.profile"
mkdir -p "$konsole_dir"
cat <<'EOF' | atomic_write_file "$konsole_profile"
[General]
Name=Dotfiles Parrot CTF
Parent=FALLBACK/

[Appearance]
Font=Hack Nerd Font Mono,10,-1,5,50,0,0,0,0,0
EOF

if command_exists kwriteconfig6; then
  kwriteconfig=kwriteconfig6
elif command_exists kwriteconfig5; then
  kwriteconfig=kwriteconfig5
else
  die "Konsole configuration requires kwriteconfig6 or kwriteconfig5"
fi

"$kwriteconfig" --file konsolerc --group 'Desktop Entry' \
  --key DefaultProfile Dotfiles-Parrot-CTF.profile

# Parrot Konsole follows the account login shell. Deliberately omit Command=
# so this profile does not create a competing terminal-specific shell policy.
success "Parrot Konsole profile and terminal themes installed"
