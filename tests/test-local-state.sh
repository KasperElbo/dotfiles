#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

run_setup() {
  local home="$1"
  local flavour="$2"
  HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    "$repo_root/scripts/setup-local.sh" "$flavour" >/dev/null
}

fresh_home="$test_root/fresh-home"
mkdir -p "$fresh_home"
run_setup "$fresh_home" frappe

grep -Fqx frappe "$fresh_home/.config/dotfiles/theme"
grep -Fqx 'theme = catppuccin-frappe.conf' \
  "$fresh_home/.config/dotfiles/ghostty.conf"
# The dollar-prefixed string is a literal Sway variable.
# shellcheck disable=SC2016
grep -Fq 'set $wallpaper' "$fresh_home/.config/dotfiles/sway-theme.conf"
grep -Fq 'background=303446f2' "$fresh_home/.config/dotfiles/fuzzel.ini"

for identity in local drdk; do
  identity_path="$fresh_home/.config/git/$identity"
  [[ -f "$identity_path" && ! -L "$identity_path" ]]
  [[ ! -s "$identity_path" ]]
done

printf 'user-owned\n' >"$fresh_home/notes.txt"
ln -s notes.txt "$fresh_home/notes-link"
printf 'keep-local-identity\n' >"$fresh_home/external-identity"
rm -- "$fresh_home/.config/git/local"
ln -s "$fresh_home/external-identity" "$fresh_home/.config/git/local"

run_setup "$fresh_home" mocha

grep -Fqx frappe "$fresh_home/.config/dotfiles/theme"
grep -Fqx user-owned "$fresh_home/notes.txt"
[[ "$(readlink "$fresh_home/notes-link")" == notes.txt ]]
[[ "$(readlink "$fresh_home/.config/git/local")" == \
  "$fresh_home/external-identity" ]]
printf 'PASS: fresh and repeated setup preserve user-managed state\n'

sway_home="$test_root/sway-home"
mkdir -p "$sway_home"
HOME="$sway_home" \
  XDG_CONFIG_HOME="$sway_home/.config" \
  XDG_DATA_HOME="$sway_home/.local/share" \
  "$repo_root/scripts/setup-local.sh" mocha --sway >/dev/null

local_sway="$sway_home/.config/sway/local.conf"
[[ -f "$local_sway" && ! -L "$local_sway" ]]
printf 'output DP-9 mode 1920x1080\n' >"$local_sway"

HOME="$sway_home" \
  XDG_CONFIG_HOME="$sway_home/.config" \
  XDG_DATA_HOME="$sway_home/.local/share" \
  "$repo_root/scripts/setup-local.sh" latte --sway >/dev/null

grep -Fqx 'output DP-9 mode 1920x1080' "$local_sway"
printf 'PASS: local Sway output configuration remains machine-owned\n'

migration_home="$test_root/migration-home"
mkdir -p "$migration_home/.config/git"

for identity in local drdk; do
  ln -s "$repo_root/git/.config/git/$identity" \
    "$migration_home/.config/git/$identity"
done

run_setup "$migration_home" macchiato

for identity in local drdk; do
  identity_path="$migration_home/.config/git/$identity"
  [[ -f "$identity_path" && ! -L "$identity_path" ]]
  grep -Fq '[user]' "$identity_path"
  [[ "$(stat -c '%a' "$identity_path")" == 600 ]]
done

printf 'PASS: legacy Stow-managed Git identities migrate to local files\n'
