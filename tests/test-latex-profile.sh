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

assert_contains "$repo_root/nvim-lazyvim/.config/nvim/lua/config/profile.lua" \
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

# ---------------------------------------------------------------------------
# Platform ownership contract
#
# The macOS model is "externally managed": the installer owns no TeX provider,
# so it must say so rather than advertising a flag it does not implement, and
# the smoke runner must distinguish an expected absence from a broken install.
# ---------------------------------------------------------------------------

manifest="$repo_root/config/capabilities.tsv"
macos_latex_row="$(awk -F '\t' '$1 == "latex" && $2 == "macos" { print; exit }' "$manifest")"
[[ -n "$macos_latex_row" ]] || fail "the capability manifest has no latex/macos row"
IFS=$'\t' read -r _ _ _ macos_flag _ _ _ macos_provider _ _ _ _ macos_docs _ macos_status \
  <<<"$macos_latex_row"
[[ "$macos_status" == unsupported ]] ||
  fail "latex/macos claims status $macos_status while no macOS TeX provider exists"
[[ "$macos_provider" == user-managed ]] ||
  fail "latex/macos must name its absence owner, found provider $macos_provider"
[[ "$macos_flag" == - ]] ||
  fail "latex/macos must declare no CLI flag, found $macos_flag"
[[ "$macos_docs" == docs/macos.md* ]] ||
  fail "latex/macos must point at the macOS ownership documentation"

# The generated support table is what a reader consults; it must show the owner.
matrix_latex_row="$(grep -E '^\| .latex. \|' "$repo_root/docs/capability-matrix.md")"
[[ "$matrix_latex_row" == *'— user-managed'* ]] ||
  fail "the generated matrix does not show the user-managed LaTeX absence"

# An unimplemented flag must be refused with an actionable message, never
# accepted and never reported as a generic unknown option.
macos_installer_output="$("$repo_root/install.sh" --platform macos --latex 2>&1 || true)"
case "$macos_installer_output" in
*"not a macOS option"*"externally managed on macOS"*) ;;
*) fail "macOS installer does not explain why --latex is unavailable: $macos_installer_output" ;;
esac
case "$macos_installer_output" in
*"Unknown option"*) fail "macOS installer treats --latex as an unrecognized option" ;;
esac
macos_help="$("$repo_root/install.sh" --platform macos --help 2>&1)"
case "$macos_help" in
*--latex*) fail "macOS help advertises --latex, which the installer does not implement" ;;
esac

# The documented ownership answers must actually be in the documentation.
macos_docs_file="$repo_root/docs/macos.md"
assert_contains "$macos_docs_file" 'LaTeX is externally managed on macOS'
assert_contains "$macos_docs_file" 'latexmk'
assert_contains "$macos_docs_file" 'Mason, from the shared'
assert_contains "$macos_docs_file" 'macOS itself, through'

# The smoke runner distinguishes an expected absence from a broken install.
dev_workflows="$repo_root/scripts/test-dev-workflows.sh"
assert_contains "$dev_workflows" 'install_lifecycle_capability_selected latex'
assert_contains "$dev_workflows" 'TeX is externally managed on macOS'

printf 'Optional LaTeX ownership and workflow configuration passed.\n'
