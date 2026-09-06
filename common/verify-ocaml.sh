#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

state_file="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"

[[ -f "$state_file" ]] || die "OCaml profile state is missing: $state_file"
require_command opam

switch_name="$(awk -F= '$1 == "switch" { print $2 }' "$state_file")"
compiler_version="$(awk -F= '$1 == "compiler" { print $2 }' "$state_file")"

[[ "$switch_name" =~ ^dotfiles-ocaml-[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Invalid OCaml switch in $state_file"
[[ "$compiler_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Invalid OCaml compiler version in $state_file"

opam switch list --short | grep -Fxq "$switch_name" ||
  die "Configured opam switch not found: $switch_name"

actual_compiler="$(opam exec --switch "$switch_name" -- ocamlc -version)"
[[ "$actual_compiler" == "$compiler_version" ]] ||
  die "OCaml compiler mismatch: expected $compiler_version, found $actual_compiler"

commands=(dune ocamlearlybird ocamllsp ocamlformat utop)

for command_name in "${commands[@]}"; do
  opam exec --switch "$switch_name" -- sh -c \
    'command -v "$1" >/dev/null' sh "$command_name" ||
    die "opam-managed command missing from $switch_name: $command_name"
done

success "OCaml $compiler_version and opam-managed development tools verified"
