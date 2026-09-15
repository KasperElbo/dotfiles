#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

command_exists dnf || die "OCaml prerequisite installation currently supports Fedora/DNF systems only."

wsl="false"
while (($#)); do
  case "$1" in
  --wsl) wsl="true" ;;
  *) die "Unknown option: $1" ;;
  esac
  shift
done

# Fedora owns the package manager and native build prerequisites. opam owns
# every compiler switch and OCaml ecosystem package installed afterwards.
# The WSL baseline already owns compiler/build prerequisites. The workstation
# baseline does not, so this optional provider owns them there.
# The two sets are named apart so config/capabilities.tsv can be checked
# against the one that belongs to each platform's ocaml row.
if [[ "$wsl" == "true" ]]; then
  wsl_packages=(bubblewrap m4 opam patch pkgconf-pkg-config)
  packages=("${wsl_packages[@]}")
else
  workstation_packages=(
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
  packages=("${workstation_packages[@]}")
fi

info "Installing Fedora-owned OCaml prerequisites"
sudo dnf install -y "${packages[@]}"

success "OCaml prerequisites installed"
