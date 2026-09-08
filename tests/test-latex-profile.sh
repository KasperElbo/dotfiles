#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
latex_installer="$repo_root/platforms/fedora/scripts/install-latex.sh"
latex_config="$repo_root/nvim-lazyvim/.config/nvim/lua/plugins/latex.lua"
wsl_config="$repo_root/platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua"
fixture="$repo_root/tests/fixtures/latex-smoke"

fail() {
  printf 'LaTeX profile test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local value="$2"

  grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

for package in latexmk biber texlive-biblatex texlive-latexindent; do
  assert_contains "$latex_installer" "  $package"
done

assert_contains "$repo_root/nvim-lazyvim/.config/nvim/lazyvim.json" \
  'lazyvim.plugins.extras.lang.tex'
assert_contains "$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt" 'texlab'

assert_contains "$latex_config" 'vim.g.vimtex_compiler_method = "latexmk"'
assert_contains "$latex_config" 'vim.g.vimtex_quickfix_open_on_warning = 0'
assert_contains "$latex_config" 'vim.fn.executable("okular") == 1'
assert_contains "$latex_config" 'vim.g.vimtex_view_general_viewer = "xdg-open"'
assert_contains "$latex_config" 'if not vim.g.vimtex_view_general_viewer then'
assert_contains "$wsl_config" 'vim.g.vimtex_view_general_viewer = "wsl-open"'
assert_contains "$wsl_config" 'vim.g.vimtex_view_general_options = "@pdf"'
assert_contains "$latex_config" 'onSave = false'
assert_contains "$latex_config" 'onOpenAndSave = false'
assert_contains "$latex_config" 'latexFormatter = "latexindent"'

for binding in ll lv le lo lt li; do
  assert_contains "$latex_config" "<localleader>$binding"
done

assert_contains "$fixture/.latexmkrc" "@default_files = ('main.tex');"
assert_contains "$fixture/main.tex" '\input{sections/details}'
assert_contains "$fixture/main.tex" '\printbibliography'
assert_contains "$fixture/sections/details.tex" '% !TeX root = ../main.tex'
assert_contains "$fixture/sections/details.tex" '\ref{sec:introduction}'
assert_contains "$fixture/sections/details.tex" '\parencite{vimtex}'

assert_contains "$repo_root/scripts/test-dev-workflows.sh" '--latex'
assert_contains "$repo_root/scripts/test-dev-workflows.sh" \
  "latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex"
assert_contains "$repo_root/scripts/test-dev-workflows.sh" \
  'ThisCommandDeliberatelyDoesNotExist'

printf 'Optional LaTeX ownership and workflow configuration passed.\n'
