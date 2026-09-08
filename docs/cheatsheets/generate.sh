#!/usr/bin/env bash
# Render the printable keyboard cheat sheets from their tracked LaTeX source.
#
# Usage:
#   docs/cheatsheets/generate.sh              # build all four PDFs
#   docs/cheatsheets/generate.sh fedora-sway   # build just one
#
# Output PDFs are NOT committed to the repository (see docs/cheatsheets/README.md):
# they are always rebuilt from the .tex source below, so there is nothing that
# can go stale. Requires a LaTeX toolchain (a normal TeX Live install already
# satisfies this; on Fedora, `sudo dnf install texlive-scheme-medium latexmk`,
# the same packages this repository's own `--latex` profile installs).
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

sheets=(fedora-kde fedora-sway fedora-wsl macos)
if (($# > 0)); then
  sheets=("$@")
fi

command -v latexmk >/dev/null 2>&1 || {
  printf 'latexmk is required (part of a normal TeX Live install).\n' >&2
  printf 'Fedora: sudo dnf install texlive-scheme-medium latexmk\n' >&2
  exit 1
}

# A fixed SOURCE_DATE_EPOCH makes the PDF's embedded timestamp/ID
# reproducible: rebuilding from unchanged source bytes reproduces the same
# PDF bytes, rather than a new one every run.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

for sheet in "${sheets[@]}"; do
  [[ -f "$sheet.tex" ]] || {
    printf 'No such cheat sheet source: %s.tex\n' "$sheet" >&2
    exit 1
  }
  printf 'Building %s.pdf...\n' "$sheet"
  latexmk -pdf -interaction=nonstopmode -halt-on-error -quiet "$sheet.tex"
done

latexmk -c "${sheets[@]/%/.tex}" >/dev/null 2>&1 || true

printf '\nDone. PDFs are in %s (untracked; regenerate any time with this script).\n' "$script_dir"
