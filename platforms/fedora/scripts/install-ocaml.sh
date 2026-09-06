#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

command_exists dnf || die "OCaml prerequisite installation currently supports Fedora/DNF systems only."

# Fedora owns the package manager and native build prerequisites. opam owns
# every compiler switch and OCaml ecosystem package installed afterwards.
packages=(
  bzip2
  bubblewrap
  gcc
  gcc-c++
  m4
  make
  opam
  patch
  pkgconf-pkg-config
  unzip
)

info "Installing Fedora-owned OCaml prerequisites"
sudo dnf install -y "${packages[@]}"

success "OCaml prerequisites installed"
