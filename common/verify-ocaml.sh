#!/usr/bin/env bash
set -u

# Optional OCaml/opam profile verification.
#
# This is the single OCaml verifier for every platform. It answers three
# distinct questions rather than one, because "opam is absent" means something
# completely different depending on whether the profile was ever selected:
#
#   profile unselected and not installed -> PASS (not applicable)
#   profile selected and healthy         -> PASS
#   profile selected and missing/broken  -> FAIL
#
# Selection is read from authoritative state, never from an ad-hoc flag: the
# install lifecycle records which capabilities a run asked for, and the OCaml
# profile state records what opam actually produced. Every OCaml command runs
# inside an explicit opam environment, so the result never depends on a
# restarted login shell and is valid in the same process that just installed.

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/verify.sh"
# shellcheck source=lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/profile-state.sh"
# shellcheck source=lib/install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/install-lifecycle.sh"

verify_reset

state_file="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"
opam_init_hook="$HOME/.opam/opam-init/init.zsh"

# The opam-managed commands the profile installs. ocamlearlybird comes from the
# earlybird package and ocamllsp from ocaml-lsp-server, so the command names
# deliberately differ from the package names in common/install-ocaml.sh.
OCAML_REQUIRED_COMMANDS=(dune ocamlearlybird ocamllsp ocamlformat utop)

selection_status=0
install_lifecycle_capability_selected ocaml || selection_status=$?

section "Optional OCaml profile"

if [[ ! -f "$state_file" ]]; then
  if ((selection_status == 0)); then
    fail "The OCaml capability is selected in $(install_state_path) but its" \
      "profile state is missing: $state_file"
    finish_verification "OCaml profile verification"
    exit $?
  fi

  pass "OCaml profile is not selected and not installed (not applicable)"
  if command_exists opam; then
    warning "opam is on PATH at $(command -v opam) but no OCaml profile state" \
      "exists; it is not owned by these dotfiles"
  else
    pass "opam is absent, as expected for an unselected profile"
  fi
  finish_verification "OCaml profile verification"
  exit $?
fi

# --- Selected profile -------------------------------------------------------

if profile_state_validate_file "$state_file" ocaml >/dev/null 2>&1; then
  pass "OCaml profile state is valid: $state_file"
else
  fail "OCaml profile state is not a valid ocaml state file: $state_file"
  finish_verification "OCaml profile verification"
  exit $?
fi

switch_name="$(profile_state_read "$state_file" switch ocaml)"
compiler_version="$(profile_state_read "$state_file" compiler ocaml)"

if [[ "$compiler_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "Configured OCaml compiler is a stable release: $compiler_version"
else
  fail "Invalid OCaml compiler version in $state_file: ${compiler_version:-empty}"
fi

# The switch name is derived from the compiler, so an OCAML_COMPILER_VERSION
# override only round-trips correctly when both recorded values still agree.
if [[ "$switch_name" == "dotfiles-ocaml-$compiler_version" ]]; then
  pass "Recorded switch matches the recorded compiler: $switch_name"
else
  fail "Recorded switch $switch_name does not match compiler $compiler_version;" \
    "expected dotfiles-ocaml-$compiler_version"
fi

if ((VERIFY_FAILURES > 0)); then
  finish_verification "OCaml profile verification"
  exit $?
fi

# --- opam ownership ---------------------------------------------------------
#
# A bare PATH hit proves nothing: the point of the optional profile is that the
# platform's native provider owns opam, and opam alone owns everything inside
# the switch. An opam under $HOME, inside a mise data directory, or anywhere
# else outside the native prefix is somebody else's opam, and a switch it
# manages is not the one this profile installed.
#
# The prefix itself is platform knowledge, so a platform verifier passes it in
# through DOTFILES_NATIVE_PREFIX. The fallback exists only so a standalone run
# of this script still checks something meaningful; it maps a recorded platform
# identifier to its documented prefix and never invokes a package manager.

opam_path="$(command -v opam 2>/dev/null || true)"
if [[ -z "$opam_path" ]]; then
  fail "The OCaml profile is installed but opam is not available;" \
    "reinstall it with the platform's OCaml prerequisites step"
  finish_verification "OCaml profile verification"
  exit $?
fi
pass "opam: $opam_path"

ocaml_platform="$(install_lifecycle_platform 2>/dev/null || true)"
if [[ -z "$ocaml_platform" ]]; then
  case "$(uname -s 2>/dev/null || true)" in
  Darwin) ocaml_platform=macos ;;
  *) ocaml_platform=unknown ;;
  esac
fi

native_prefix="${DOTFILES_NATIVE_PREFIX:-}"
if [[ -z "$native_prefix" ]]; then
  case "$ocaml_platform" in
  # Homebrew's prefix is relocatable, so prefer what Homebrew itself exports.
  macos) native_prefix="${HOMEBREW_PREFIX:-/opt/homebrew}" ;;
  fedora | fedora-wsl) native_prefix=/usr ;;
  esac
fi

opam_canonical="$(verify_canonical_existing_path "$opam_path" 2>/dev/null || printf '%s' "$opam_path")"
# Compare canonical against canonical. On macOS a temporary or symlinked prefix
# resolves elsewhere, and a prefix check that compared one canonical path
# against one unresolved one would reject a perfectly owned opam.
if [[ -n "$native_prefix" ]]; then
  native_prefix="$(verify_canonical_existing_path "$native_prefix" 2>/dev/null || printf '%s' "$native_prefix")"
  native_prefix="${native_prefix%/}"
fi
if [[ -z "$native_prefix" ]]; then
  not_observed "The native package prefix for platform ${ocaml_platform} is" \
    "unknown here, so ownership of $opam_canonical was not confirmed"
elif [[ "$opam_canonical" == "$native_prefix"/* ]]; then
  pass "opam is owned by the platform's native provider under $native_prefix:" \
    "$opam_canonical"
else
  fail "opam resolves to $opam_canonical, outside the native package prefix" \
    "$native_prefix; this is not the opam the OCaml profile installed"
fi

# --- Switch, compiler and tools --------------------------------------------

if opam switch list --short 2>/dev/null | grep -Fxq "$switch_name"; then
  pass "Configured opam switch exists: $switch_name"
else
  fail "Configured opam switch not found: $switch_name"
  finish_verification "OCaml profile verification"
  exit $?
fi

# `opam switch show` answers for the directory it runs in, and a project-local
# switch legitimately wins there. Ask from a neutral directory so this asserts
# the global default the installer set, not wherever the verifier was started.
neutral_dir="$(mktemp -d)" || neutral_dir=""
if [[ -n "$neutral_dir" ]]; then
  selected_switch="$(cd "$neutral_dir" && opam switch show 2>/dev/null || true)"
  rm -rf -- "$neutral_dir"
else
  selected_switch="$(opam switch show 2>/dev/null || true)"
fi
if [[ "$selected_switch" == "$switch_name" ]]; then
  pass "Selected opam switch is the configured one: $selected_switch"
else
  fail "Selected opam switch is ${selected_switch:-unknown}, not the configured $switch_name"
fi

actual_compiler="$(opam exec --switch "$switch_name" -- ocamlc -version 2>/dev/null || true)"
if [[ "$actual_compiler" == "$compiler_version" ]]; then
  pass "OCaml compiler in $switch_name is $compiler_version"
else
  fail "OCaml compiler mismatch in $switch_name: expected $compiler_version," \
    "found ${actual_compiler:-none}"
fi

for command_name in "${OCAML_REQUIRED_COMMANDS[@]}"; do
  # shellcheck disable=SC2016 # The command name is evaluated by the inner sh.
  if opam exec --switch "$switch_name" -- sh -c \
    'command -v "$1" >/dev/null' sh "$command_name" 2>/dev/null; then
    pass "opam-managed command present in $switch_name: $command_name"
  else
    fail "opam-managed command missing from $switch_name: $command_name"
  fi
done

if opam exec --switch "$switch_name" -- dune --version >/dev/null 2>&1; then
  pass "dune runs inside the switch environment"
else
  fail "dune did not run inside $switch_name"
fi

# --- Generated shell hook ---------------------------------------------------
#
# The profile deliberately installs opam with --no-setup and sources the
# generated hook from tracked Zsh configuration instead, so the hook is part of
# the contract even though nothing here depends on a restarted shell.

if [[ -s "$opam_init_hook" ]]; then
  pass "Generated opam shell hook exists: $opam_init_hook"
  if command_exists zsh; then
    if zsh -n "$opam_init_hook" >/dev/null 2>&1; then
      pass "Generated opam shell hook parses as Zsh"
    else
      fail "Generated opam shell hook is not valid Zsh: $opam_init_hook"
    fi
  else
    not_observed "zsh is unavailable, so $opam_init_hook could not be parsed here"
  fi
else
  fail "Generated opam shell hook is missing or empty: $opam_init_hook"
fi

# --- Harmless compile -------------------------------------------------------
#
# Every check above can pass on a switch whose compiler cannot actually build
# anything. Compiling and running one throwaway bytecode program is the
# cheapest proof that the selected profile works, and it runs entirely inside
# the explicit opam environment.

compile_dir="$(mktemp -d)" || compile_dir=""
if [[ -z "$compile_dir" ]]; then
  fail "Could not create a temporary directory for the OCaml compile check"
else
  printf 'let () = print_string "dotfiles-ocaml-ok"\n' >"$compile_dir/probe.ml"
  compile_output="$(
    cd "$compile_dir" &&
      opam exec --switch "$switch_name" -- ocamlc -o probe probe.ml >/dev/null 2>&1 &&
      ./probe 2>/dev/null
  )" || compile_output=""
  if [[ "$compile_output" == dotfiles-ocaml-ok ]]; then
    pass "A throwaway OCaml program compiles and runs in $switch_name"
  else
    fail "A throwaway OCaml program did not compile and run in $switch_name"
  fi
  rm -rf -- "$compile_dir"
fi

finish_verification "OCaml profile verification"
