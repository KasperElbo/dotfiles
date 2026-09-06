#!/usr/bin/env bash
set -euo pipefail

flavour="${1:-}"

case "$flavour" in
latte)
  global_theme="Catppuccin-Latte-Mauve"
  color_scheme="CatppuccinLatteMauve"
  cursor_theme="catppuccin-latte-mauve-cursors"
  ;;
frappe)
  global_theme="Catppuccin-Frappe-Mauve"
  color_scheme="CatppuccinFrappeMauve"
  cursor_theme="catppuccin-frappe-mauve-cursors"
  ;;
macchiato)
  global_theme="Catppuccin-Macchiato-Mauve"
  color_scheme="CatppuccinMacchiatoMauve"
  cursor_theme="catppuccin-macchiato-mauve-cursors"
  ;;
mocha)
  global_theme="Catppuccin-Mocha-Mauve"
  color_scheme="CatppuccinMochaMauve"
  cursor_theme="catppuccin-mocha-mauve-cursors"
  ;;
*)
  echo "Usage: $0 {latte|frappe|macchiato|mocha}" >&2
  exit 1
  ;;
esac

echo "Applying Catppuccin $flavour to KDE..."

lookandfeeltool --apply "$global_theme"
plasma-apply-colorscheme "$color_scheme"
plasma-apply-cursortheme "$cursor_theme"
