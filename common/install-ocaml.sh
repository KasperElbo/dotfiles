#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command opam

compiler_version="${OCAML_COMPILER_VERSION:-5.5.0}"
switch_name="dotfiles-ocaml-${compiler_version}"
state_file="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"

[[ "$compiler_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "OCAML_COMPILER_VERSION must be a stable x.y.z release"

if ! opam var root >/dev/null 2>&1; then
  info "Initializing opam without modifying shell startup files"
  opam init --bare --no-setup --yes
fi

info "Refreshing the opam package index"
opam update --yes

if opam switch list --short | grep -Fxq "$switch_name"; then
  info "Using existing opam switch $switch_name"
else
  info "Creating opam switch $switch_name with OCaml $compiler_version"
  opam switch create "$switch_name" "$compiler_version" --yes
fi

info "Installing the OCaml Platform tools in $switch_name"
opam install --switch "$switch_name" --yes \
  dune \
  earlybird \
  ocaml-lsp-server \
  ocamlformat \
  utop

# Make the profile switch the global default. Project-local switches still win
# automatically when commands are run from inside their directory.
opam switch set "$switch_name"

ensure_dir "$(dirname "$state_file")"
atomic_write_file "$state_file" <<EOF
switch=$switch_name
compiler=$compiler_version
EOF

success "OCaml $compiler_version development environment installed"

printf '\n'
printf 'Start a new shell, or activate it now with:\n'
printf '  eval "$(opam env --switch=%s --set-switch --shell=zsh)"\n' \
  "$switch_name"
