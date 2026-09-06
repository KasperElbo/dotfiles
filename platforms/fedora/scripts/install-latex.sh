#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

command_exists dnf || die "LaTeX installation currently supports Fedora/DNF systems only."

packages=(
  texlive-scheme-medium
  biber
)

info "Installing LaTeX toolchain"
sudo dnf install -y "${packages[@]}"

success "LaTeX toolchain installed"

printf '\n'
printf 'Installed tooling should include:\n'
printf '  latex / pdflatex / xelatex / lualatex\n'
printf '  latexmk\n'
printf '  latexindent\n'
printf '  biber\n'
