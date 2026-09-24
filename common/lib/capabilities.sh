#!/usr/bin/env bash

# Reads of config/capabilities.tsv and config/command-providers.tsv.
#
# This library deliberately does not select shell options. It resolves the
# manifests from DOTFILES_ROOT and reports through die, both from lib/common.sh,
# and sources that itself when the caller has not.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
# shellcheck source=manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"

CAPABILITY_MANIFEST="${CAPABILITY_MANIFEST:-$DOTFILES_ROOT/config/capabilities.tsv}"
COMMAND_PROVIDER_MANIFEST="${COMMAND_PROVIDER_MANIFEST:-$DOTFILES_ROOT/config/command-providers.tsv}"

# One field of a capability row, read by column name (see manifest.sh). Exit 1
# when the platform has no such capability row; a manifest whose header lacks
# the field fails loudly instead.
capability_field() {
  local platform="$1" capability="$2" field="$3"
  manifest_field "$CAPABILITY_MANIFEST" "$field" \
    capability "$capability" platform "$platform"
}

# capability_packages <platform> <capability>: the row's declared packages,
# one per line, in manifest order. A row that declares none ("-") prints
# nothing; a row that does not exist fails, so a verifier looping over the
# result cannot silently check an empty set because a name was mistyped.
capability_packages() {
  local platform="$1" capability="$2" packages package
  local -a declared=()
  packages="$(capability_field "$platform" "$capability" packages)" || return 1
  [[ "$packages" != - ]] || return 0
  IFS=, read -r -a declared <<<"$packages"
  for package in "${declared[@]}"; do
    printf '%s\n' "$package"
  done
}

capability_is_selected() {
  local wanted="$1" selected
  shift
  for selected in "$@"; do [[ "$selected" != "$wanted" ]] || return 0; done
  return 1
}

capability_validate_selection() {
  local platform="$1" capability dependency conflict status values
  local -a dependencies=() conflicts=()
  shift
  for capability in "$@"; do
    status="$(capability_field "$platform" "$capability" status || true)"
    [[ "$status" == implemented ]] || {
      printf 'Capability %s is not implemented for %s.\n' "$capability" "$platform" >&2; return 1;
    }
    values="$(capability_field "$platform" "$capability" dependencies)" || return
    IFS=, read -r -a dependencies <<<"$values"
    for dependency in "${dependencies[@]}"; do
      [[ "$dependency" == - ]] || capability_is_selected "$dependency" "$@" || {
        printf 'Capability %s requires %s on %s.\n' "$capability" "$dependency" "$platform" >&2; return 1;
      }
    done
    values="$(capability_field "$platform" "$capability" conflicts)" || return
    IFS=, read -r -a conflicts <<<"$values"
    for conflict in "${conflicts[@]}"; do
      [[ "$conflict" == - ]] || ! capability_is_selected "$conflict" "$@" || {
        printf 'Capability %s conflicts with %s on %s.\n' "$capability" "$conflict" "$platform" >&2; return 1;
      }
    done
  done
}

# capability_stow_package_root <platform> <package>: the directory the package
# is stowed from. A package at the top of the checkout is shared by every
# platform that names it; anything else belongs to the platform naming it.
# This is where that rule lives: the installer's preflight and each platform's
# Stow script both resolve through it, so they cannot disagree about which
# copy of a package a machine gets.
capability_stow_package_root() {
  local platform="$1" package="$2"

  if [[ -d "$DOTFILES_ROOT/$package" ]]; then
    printf '%s\n' "$DOTFILES_ROOT"
  else
    printf '%s\n' "$DOTFILES_ROOT/platforms/$platform/stow"
  fi
}

capability_stow_specs() {
  local platform="$1" capability packages package package_root
  local -a stow_packages=()
  shift
  for capability in "$@"; do
    packages="$(capability_field "$platform" "$capability" stow)" || return
    [[ "$packages" != - ]] || continue
    IFS=, read -r -a stow_packages <<<"$packages"
    for package in "${stow_packages[@]}"; do
      package_root="$(capability_stow_package_root "$platform" "$package")"
      printf '%s::%s\n' "$package_root" "$package"
    done
  done
}

# Print pre-mutation command requirements as command<TAB>provider<TAB>class.
# config/command-providers.tsv is the one home for the commands every bash
# platform's installer checks before it mutates the host; the Fedora rows also
# close the wider Fedora bootstrap boundary. Package ownership remains in the
# capability manifest rather than being duplicated here. A bootstrap-package
# command is checked here too: common/lib/base-bootstrap.sh installs it before
# the installer starts, so by preflight it is there, and this says so if not.
capability_preflight_command_specs() {
  local wanted_platform="$1" rows command provider classification

  [[ -r "$COMMAND_PROVIDER_MANIFEST" ]] || {
    printf 'Command provider manifest is not readable: %s\n' \
      "$COMMAND_PROVIDER_MANIFEST" >&2
    return 1
  }
  rows="$(manifest_values "$COMMAND_PROVIDER_MANIFEST" \
    command,provider,classification platform "$wanted_platform")" || return 1

  while IFS=$'\t' read -r command provider classification; do
    case "$classification" in
    bootstrap-prerequisite | bootstrap-package | supported-base)
      printf '%s\t%s\t%s\n' "$command" "$provider" "$classification"
      ;;
    esac
  done <<<"$rows"
}
