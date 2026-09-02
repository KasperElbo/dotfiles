#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/starship/.config/starship/template.toml"
output_dir="$repo_root/starship/.config/starship"

flavours=(
  latte
  frappe
  macchiato
  mocha
)

if [[ ! -f "$template" ]]; then
  echo "Starship template not found: $template" >&2
  exit 1
fi

for flavour in "${flavours[@]}"; do
  sed -E \
    "s/^palette = ['\"]catppuccin_[a-z]+['\"]/palette = 'catppuccin_${flavour}'/" \
    "$template" \
    >"$output_dir/catppuccin-${flavour}.toml"

  echo "Generated catppuccin-${flavour}.toml"
done
