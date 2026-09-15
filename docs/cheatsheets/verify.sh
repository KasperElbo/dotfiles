#!/usr/bin/env bash
# Compile every printable cheat sheet and prove it is still printable.
#
# The sheets are curated artifacts with a page budget: a sheet that silently
# grows to three pages, or whose last table row falls off the edge, is a
# regression even though LaTeX reports success. This checks four things that a
# plain compile does not:
#
#   budget        each sheet stays within its declared page count, on A4
#   overflow      no overfull box wider than the tolerance below, which is
#                 what clipped or bleeding content looks like in the log
#   references    no undefined reference or citation
#   determinism   compiling twice from unchanged source produces identical
#                 PDF bytes, so "regenerate it yourself" stays a real promise
#
# PDF bytes are only reproducible because generate.sh pins SOURCE_DATE_EPOCH;
# without that the timestamp alone would differ and a byte comparison would be
# meaningless.
#
# Usage:
#   docs/cheatsheets/verify.sh              # every sheet
#   docs/cheatsheets/verify.sh fedora-sway  # one sheet
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

# sheet:maximum-pages. One page for a reduced profile, two where the shared
# terminal/development block is included in full on its own page.
declare -A page_budget=(
  [fedora-kde]=1
  [fedora-sway]=2
  [fedora-wsl]=2
  [macos]=2
  [parrot-ctf]=1
)

# An overfull box under this is normal LaTeX micro-typography; above it, content
# is visibly outside the text block.
overfull_tolerance_pt=1

sheets=(fedora-kde fedora-sway fedora-wsl macos parrot-ctf)
if (($# > 0)); then
  sheets=("$@")
fi

for tool in latexmk pdfinfo sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required to verify the printable cheat sheets.\n' "$tool" >&2
    printf 'Fedora: sudo dnf install texlive-scheme-medium latexmk poppler-utils\n' >&2
    exit 2
  }
done

failures=0
fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}
pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

work="$(mktemp -d)"
trap 'rm -rf -- "$work"; latexmk -c "${sheets[@]/%/.tex}" >/dev/null 2>&1 || true' EXIT

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

for sheet in "${sheets[@]}"; do
  budget="${page_budget[$sheet]:-}"
  if [[ -z "$budget" ]]; then
    fail "$sheet has no declared page budget; add one to $0"
    continue
  fi
  [[ -f "$sheet.tex" ]] || {
    fail "no such cheat sheet source: $sheet.tex"
    continue
  }

  if ! latexmk -pdf -interaction=nonstopmode -halt-on-error -quiet "$sheet.tex" \
    >"$work/$sheet.build" 2>&1; then
    fail "$sheet does not compile"
    sed -n '1,60p' "$work/$sheet.build" >&2
    continue
  fi
  cp -- "$sheet.pdf" "$work/$sheet.first.pdf"

  pages="$(pdfinfo "$sheet.pdf" | awk '/^Pages:/ { print $2 }')"
  if [[ "$pages" -gt "$budget" ]]; then
    fail "$sheet renders $pages pages; the budget is $budget"
  else
    pass "$sheet: $pages page(s), budget $budget"
  fi

  page_size="$(pdfinfo "$sheet.pdf" | sed -n 's/^Page size: *//p' | head -n 1)"
  case "$page_size" in
  *"595.276 x 841.89"*) pass "$sheet: A4" ;;
  *) fail "$sheet is not A4: $page_size" ;;
  esac

  overfull="$(
    grep -c "Overfull \\\\hbox ([0-9]\\+\\.[0-9]\\+pt" "$sheet.log" 2>/dev/null || true
  )"
  if ((overfull > 0)); then
    excessive="$(
      sed -n 's/.*Overfull \\hbox (\([0-9]*\)\.[0-9]*pt too wide.*/\1/p' "$sheet.log" |
        awk -v limit="$overfull_tolerance_pt" '$1 > limit' | wc -l
    )"
    if ((excessive > 0)); then
      fail "$sheet has $excessive overfull box(es) wider than ${overfull_tolerance_pt}pt (clipped content)"
      grep -n "Overfull" "$sheet.log" | head -n 10 >&2
    else
      pass "$sheet: no overfull box beyond ${overfull_tolerance_pt}pt"
    fi
  else
    pass "$sheet: no overfull boxes"
  fi

  if grep -qE "(Reference|Citation) .* undefined" "$sheet.log"; then
    fail "$sheet has undefined references"
    grep -nE "(Reference|Citation) .* undefined" "$sheet.log" | head -n 5 >&2
  else
    pass "$sheet: no undefined references"
  fi

  # A second build from unchanged source must reproduce the same bytes.
  latexmk -c "$sheet.tex" >/dev/null 2>&1 || true
  rm -f -- "$sheet.pdf"
  if ! latexmk -pdf -interaction=nonstopmode -halt-on-error -quiet "$sheet.tex" \
    >"$work/$sheet.rebuild" 2>&1; then
    fail "$sheet does not compile on the second run"
    continue
  fi
  # sha256sum rather than cmp: the validation containers ship no diffutils,
  # and a PDF cannot be read into a shell variable for comparison.
  if [[ "$(sha256sum <"$work/$sheet.first.pdf")" == "$(sha256sum <"$sheet.pdf")" ]]; then
    pass "$sheet: reproducible across two builds"
  else
    fail "$sheet is not byte-reproducible across two builds"
  fi
done

printf '\nCheat-sheet verification: %d failure(s).\n' "$failures"
((failures == 0))
