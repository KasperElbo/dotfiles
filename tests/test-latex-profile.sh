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
IFS=$'\t' read -r _ _ _ macos_flag _ _ _ macos_provider _ _ _ _ _ macos_docs _ macos_status _ \
  <<<"$macos_latex_row"
[[ "$macos_status" == unsupported ]] ||
  fail "latex/macos claims status $macos_status while no macOS TeX provider exists"
[[ "$macos_provider" == user-managed ]] ||
  fail "latex/macos must name its absence owner, found provider $macos_provider"
[[ "$macos_flag" == - ]] ||
  fail "latex/macos must declare no CLI flag, found $macos_flag"
[[ "$macos_docs" == docs/platforms/macos.md* ]] ||
  fail "latex/macos must point at the macOS ownership documentation"

# The generated support table is what a reader consults; it must show the owner.
matrix_latex_row="$(grep -E '^\| .latex. \|' "$repo_root/docs/reference/capability-matrix.md")"
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
macos_docs_file="$repo_root/docs/platforms/macos.md"
assert_contains "$macos_docs_file" 'LaTeX is externally managed on macOS'
assert_contains "$macos_docs_file" 'latexmk'
assert_contains "$macos_docs_file" 'Mason, from the shared'
assert_contains "$macos_docs_file" 'macOS itself, through'

# The smoke runner distinguishes an expected absence from a broken install.
dev_workflows="$repo_root/scripts/test-dev-workflows.sh"
assert_contains "$dev_workflows" 'install_lifecycle_capability_selected latex'
assert_contains "$dev_workflows" 'TeX is externally managed on macOS'

# ---------------------------------------------------------------------------
# Fedora verifier contract
#
# config/capabilities.tsv names platforms/fedora/scripts/verify.sh as the
# latex/fedora verifier, so that script must reach a different verdict on a
# machine that selected the profile and one that did not. The capability keeps
# no profile state of its own (state=- in the manifest), so a fixture machine
# is the recorded installation selection plus a PATH that decides which TeX
# commands exist.
#
# The rest of that verifier describes the host it runs on — SELinux, firewalld,
# Stow links, Mason — none of which a fixture machine satisfies, so the exit
# status alone cannot say what the LaTeX section decided. Each case below
# therefore compares its failure and warning counts against the same fixture's
# LaTeX-free baseline, which isolates exactly what this section contributed.
# ---------------------------------------------------------------------------

fedora_verifier="$repo_root/platforms/fedora/scripts/verify.sh"
machine="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-latex-verify.XXXXXX")"
trap 'rm -rf -- "$machine"' EXIT

assert_lacks() {
  local file="$1"
  local value="$2"

  if grep -Fq -- "$value" "$file"; then
    fail "$file unexpectedly contains: $value"
  fi
}

# A closed PATH. The fixture alone decides which commands exist, so a developer
# machine that really does have the LaTeX profile installed cannot make these
# cases pass or fail by accident. Only what the verifier needs to read the
# installation record is linked in.
machine_bin="$machine/bin"
mkdir -p "$machine_bin"
for required_command in bash env sh awk sed grep cat head find git ls date stat \
  readlink dirname basename id mkdir rm; do
  required_path="$(command -v "$required_command" 2>/dev/null || true)"
  [[ -z "$required_path" ]] || ln -sf "$required_path" "$machine_bin/$required_command"
done

# new_machine <capabilities>: a machine whose last installation recorded
# exactly these capabilities, with no TeX on PATH.
new_machine() {
  local capabilities="$1"

  rm -rf -- "${machine:?}/home" "${machine:?}/config" "${machine:?}/data" \
    "${machine:?}/state" "${machine:?}/cache" "${machine:?}/tex"
  mkdir -p "$machine/home" "$machine/config" "$machine/data" \
    "$machine/state/dotfiles" "$machine/cache" "$machine/tex"
  cat >"$machine/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=$capabilities
observed_capabilities=$capabilities
external_assurance=not-recorded
repository=local-checkout
revision=0123456789abcdef
provenance=capability-manifest@0123456789abcdef
EOF
}

stub_tex_command() {
  local name="$1"

  {
    printf '#!/usr/bin/env bash\n'
    printf "printf '%%s\\\\n' '%s 4.83 (fixture stub)'\n" "$name"
  } >"$machine/tex/$name"
  chmod +x "$machine/tex/$name"
}

stub_tex_toolchain() {
  local name

  for name in "$@"; do
    stub_tex_command "$name"
  done
}

run_fedora_verifier() {
  local summary

  set +e
  env \
    "HOME=$machine/home" \
    "XDG_CONFIG_HOME=$machine/config" \
    "XDG_DATA_HOME=$machine/data" \
    "XDG_STATE_HOME=$machine/state" \
    "XDG_CACHE_HOME=$machine/cache" \
    "PATH=$machine/tex:$machine_bin" \
    "$fedora_verifier" >"$machine/verify.out" 2>"$machine/verify.err"
  verifier_status=$?
  set -e

  summary="$(grep -hE '[0-9]+ failure\(s\), [0-9]+ warning\(s\)' \
    "$machine/verify.out" "$machine/verify.err" | tail -n 1 || true)"
  [[ -n "$summary" ]] || fail "the Fedora verifier printed no result summary"
  verifier_failures="$(sed -E 's/.*[^0-9]([0-9]+) failure\(s\).*/\1/' <<<"$summary")"
  verifier_warnings="$(sed -E 's/.*[^0-9]([0-9]+) warning\(s\).*/\1/' <<<"$summary")"
}

latex_commands=(biber latex latexindent latexmk lualatex pdflatex xelatex)

# Baseline: no LaTeX selection, no TeX anywhere.
new_machine base,dotnet-debug
run_fedora_verifier
assert_contains "$machine/verify.out" \
  'LaTeX toolchain is not selected; its commands are not applicable'
assert_lacks "$machine/verify.err" 'latexmk'
baseline_failures="$verifier_failures"
baseline_warnings="$verifier_warnings"
printf 'PASS: an unselected LaTeX profile without TeX is reported as not applicable\n'

# TeX present without the capability: worth surfacing, not owned, never fatal.
new_machine base,dotnet-debug
stub_tex_command latexmk
run_fedora_verifier
assert_contains "$machine/verify.out" \
  'LaTeX toolchain is not selected; its commands are not applicable'
assert_contains "$machine/verify.err" "latexmk is on PATH at $machine/tex/latexmk"
assert_contains "$machine/verify.err" 'not owned by these dotfiles'
[[ "$verifier_failures" == "$baseline_failures" ]] ||
  fail "an untracked latexmk must not fail verification ($verifier_failures failures, baseline $baseline_failures)"
[[ "$verifier_warnings" == "$((baseline_warnings + 1))" ]] ||
  fail "an untracked latexmk must warn exactly once ($verifier_warnings warnings, baseline $baseline_warnings)"
printf 'PASS: TeX installed outside the capability warns without failing\n'

# Selected and complete: every command the Fedora packages provide is checked.
new_machine base,dotnet-debug,latex
stub_tex_toolchain "${latex_commands[@]}"
run_fedora_verifier
for latex_command in "${latex_commands[@]}"; do
  assert_contains "$machine/verify.out" "$latex_command: $machine/tex/$latex_command"
done
assert_contains "$machine/verify.out" 'latexmk version: latexmk 4.83'
[[ "$verifier_failures" == "$baseline_failures" ]] ||
  fail "a complete LaTeX toolchain must add no failure ($verifier_failures failures, baseline $baseline_failures)"
[[ "$verifier_warnings" == "$baseline_warnings" ]] ||
  fail "a complete LaTeX toolchain must add no warning ($verifier_warnings warnings, baseline $baseline_warnings)"
printf 'PASS: a selected LaTeX profile verifies its whole toolchain\n'

# Selected but broken: the defect DOC-004 describes must now fail.
new_machine base,dotnet-debug,latex
stub_tex_toolchain "${latex_commands[@]}"
rm -- "$machine/tex/latexmk"
run_fedora_verifier
[[ "$verifier_status" -ne 0 ]] ||
  fail 'a selected LaTeX profile without latexmk must fail verification'
assert_contains "$machine/verify.err" 'latexmk not found'
[[ "$verifier_failures" == "$((baseline_failures + 1))" ]] ||
  fail "a missing latexmk must add exactly one failure ($verifier_failures failures, baseline $baseline_failures)"
printf 'PASS: a selected LaTeX profile missing latexmk fails verification\n'

printf 'Optional LaTeX ownership and workflow configuration passed.\n'
