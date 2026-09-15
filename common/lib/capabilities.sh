#!/usr/bin/env bash

CAPABILITY_MANIFEST="${CAPABILITY_MANIFEST:-$DOTFILES_ROOT/config/capabilities.tsv}"
FEDORA_COMMAND_PROVIDER_MANIFEST="${FEDORA_COMMAND_PROVIDER_MANIFEST:-$DOTFILES_ROOT/config/fedora-command-providers.tsv}"

capability_field_number() {
  case "$1" in
  capability) printf 1 ;; platform) printf 2 ;; profile) printf 3 ;;
  cli_flag) printf 4 ;; default) printf 5 ;; dependencies) printf 6 ;;
  conflicts) printf 7 ;; provider) printf 8 ;; packages) printf 9 ;;
  stow) printf 10 ;; verifier) printf 11 ;; state) printf 12 ;;
  docs) printf 13 ;; provenance) printf 14 ;; status) printf 15 ;;
  installers) printf 16 ;;
  *) return 1 ;;
  esac
}

capability_field() {
  local platform="$1" capability="$2" field="$3" number
  number="$(capability_field_number "$field")" || return 1
  awk -F '\t' -v p="$platform" -v c="$capability" -v n="$number" \
    'NR > 1 && $1 == c && $2 == p { print $n; found=1; exit } END { exit !found }' \
    "$CAPABILITY_MANIFEST"
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
    status="$(capability_field "$platform" "$capability" status 2>/dev/null || true)"
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
# The manifest is deliberately narrow: it closes only the Fedora workstation
# and official Fedora WSL bootstrap boundary. Package ownership remains in the
# capability manifest rather than being duplicated here.
capability_preflight_command_specs() {
  local wanted_platform="$1"
  local header=true platform command provider _owner _required_by classification

  [[ -r "$FEDORA_COMMAND_PROVIDER_MANIFEST" ]] || {
    printf 'Command provider manifest is not readable: %s\n' \
      "$FEDORA_COMMAND_PROVIDER_MANIFEST" >&2
    return 1
  }

  while IFS=$'\t' read -r platform command provider _owner _required_by classification; do
    if [[ "$header" == true ]]; then
      header=false
      continue
    fi
    [[ "$platform" == "$wanted_platform" ]] || continue
    case "$classification" in
    bootstrap-prerequisite | supported-base)
      printf '%s\t%s\t%s\n' "$command" "$provider" "$classification"
      ;;
    esac
  done <"$FEDORA_COMMAND_PROVIDER_MANIFEST"
}
