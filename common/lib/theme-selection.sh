#!/usr/bin/env bash

# Where a run's Catppuccin flavour comes from (issue #148).
#
# Precedence, highest first:
#
#   explicit    --theme FLAVOUR on this invocation
#   existing    the machine's current, valid theme state file
#   remembered  the flavour in the last successful install's recorded selection
#   default     the first-install default
#
# The point of the middle two tiers is that a plain rerun must not quietly
# reset a machine to Macchiato. "existing" is checked first because it is the
# flavour the machine is actually wearing right now: `theme mocha` updates it
# without running an installer, and setup-local.sh already refuses to overwrite
# it. "remembered" then covers a machine whose theme state file is missing.
#
# Nothing here parses command text. The remembered value comes from the
# structured selection record written by the install lifecycle (#210/#211),
# read through that library's own helpers, and is validated against the current
# option manifest before it is used — a record this checkout cannot interpret
# is ignored rather than guessed at.

# shellcheck source=install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-lifecycle.sh"

THEME_DEFAULT_FLAVOUR=macchiato

# Results of theme_resolve. Shared library values consumed by sourcing scripts.
# shellcheck disable=SC2034
THEME_RESOLVED=""
# shellcheck disable=SC2034
THEME_RESOLVED_SOURCE=""

theme_flavour_is_valid() {
  case "${1:-}" in
  latte | frappe | macchiato | mocha) return 0 ;;
  *) return 1 ;;
  esac
}

theme_state_path() {
  printf '%s/dotfiles/theme\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# The flavour this machine is currently wearing, if it is one this checkout
# supports. A corrupt or unknown value is treated as absent.
theme_existing_flavour() {
  local path value
  path="$(theme_state_path)"
  [[ -r "$path" ]] || return 1
  value="$(tr -d '[:space:]' <"$path")"
  theme_flavour_is_valid "$value" || return 1
  printf '%s\n' "$value"
}

# The flavour inside the last successful install's remembered selection, for
# this platform only. Quiet by design: an absent, unreadable, foreign-platform
# or unsupported-schema record simply means "nothing remembered", which the
# next tier handles. ./install.sh --rerun remains the place that reports such
# a record loudly, because there it is a hard failure rather than a fallback.
theme_remembered_flavour() {
  local platform="$1" path selection schema recorded_platform value
  path="$(install_state_path)"
  [[ -f "$path" ]] || return 1
  profile_state_validate_file "$path" install >/dev/null 2>&1 || return 1

  selection="$(install_state_optional "$path" last_successful_selection)"
  [[ -n "$selection" ]] || return 1

  schema="$(install_state_optional "$path" selection_schema)"
  [[ "$schema" == "$INSTALL_SELECTION_SCHEMA_VERSION" ]] || return 1

  recorded_platform="$(install_state_optional "$path" last_successful_platform)"
  [[ "$recorded_platform" == "$platform" ]] || return 1

  value="$(install_selection_record_value "$selection" theme)" || return 1
  install_selection_value_is_valid "$platform" theme "$value" || return 1
  theme_flavour_is_valid "$value" || return 1
  printf '%s\n' "$value"
}

# theme_resolve <platform> <explicit:true|false> <requested-flavour>
#
# Sets THEME_RESOLVED and THEME_RESOLVED_SOURCE.
theme_resolve() {
  # THEME_RESOLVED/THEME_RESOLVED_SOURCE are this function's results, read by
  # the platform installers that source this library.
  # shellcheck disable=SC2034
  local platform="$1" explicit="$2" requested="${3:-}" value

  if [[ "$explicit" == true ]]; then
    theme_flavour_is_valid "$requested" ||
      die "Invalid Catppuccin flavour: $requested"
    THEME_RESOLVED="$requested"
    THEME_RESOLVED_SOURCE=explicit
    return 0
  fi

  if value="$(theme_existing_flavour)"; then
    THEME_RESOLVED="$value"
    THEME_RESOLVED_SOURCE=existing
    return 0
  fi

  if value="$(theme_remembered_flavour "$platform")"; then
    THEME_RESOLVED="$value"
    THEME_RESOLVED_SOURCE=remembered
    return 0
  fi

  # shellcheck disable=SC2034
  THEME_RESOLVED="$THEME_DEFAULT_FLAVOUR"
  # shellcheck disable=SC2034
  THEME_RESOLVED_SOURCE=default
}

# One line of provenance for dry-run output and the interactive confirmation.
theme_source_description() {
  case "${1:-}" in
  explicit) printf 'explicit --theme on this run\n' ;;
  existing) printf 'existing choice on this machine (%s)\n' "$(theme_state_path)" ;;
  remembered) printf 'remembered configuration of the last successful install\n' ;;
  default) printf 'first-install default\n' ;;
  *) printf 'unknown\n' ;;
  esac
}
