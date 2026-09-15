#!/usr/bin/env bash

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
    values="$(capability_field "$platform" "$capability" dependencies)"
    IFS=, read -r -a dependencies <<<"$values"
    for dependency in "${dependencies[@]}"; do
      [[ "$dependency" == - ]] || capability_is_selected "$dependency" "$@" || {
        printf 'Capability %s requires %s on %s.\n' "$capability" "$dependency" "$platform" >&2; return 1;
      }
    done
    values="$(capability_field "$platform" "$capability" conflicts)"
    IFS=, read -r -a conflicts <<<"$values"
    for conflict in "${conflicts[@]}"; do
      [[ "$conflict" == - ]] || ! capability_is_selected "$conflict" "$@" || {
        printf 'Capability %s conflicts with %s on %s.\n' "$capability" "$conflict" "$platform" >&2; return 1;
      }
    done
  done
}

capability_stow_specs() {
  local platform="$1" capability packages package package_root
  local -a stow_packages=()
  shift
  for capability in "$@"; do
    packages="$(capability_field "$platform" "$capability" stow)"
    [[ "$packages" != - ]] || continue
    IFS=, read -r -a stow_packages <<<"$packages"
    for package in "${stow_packages[@]}"; do
      if [[ -d "$DOTFILES_ROOT/$package" ]]; then
        package_root="$DOTFILES_ROOT"
      else
        package_root="$DOTFILES_ROOT/platforms/$platform/stow"
      fi
      printf '%s::%s\n' "$package_root" "$package"
    done
  done
}

# Print pre-mutation command requirements as command<TAB>provider<TAB>class.
# config/command-providers.tsv is the one home for the commands every bash
# platform's installer checks before it mutates the host; the Fedora rows also
# close the wider Fedora bootstrap boundary. Package ownership remains in the
# capability manifest rather than being duplicated here.
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
    bootstrap-prerequisite | supported-base)
      printf '%s\t%s\t%s\n' "$command" "$provider" "$classification"
      ;;
    esac
  done <<<"$rows"
}
