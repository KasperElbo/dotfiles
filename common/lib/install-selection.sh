#!/usr/bin/env bash

# Structured representation of the persistent installer selection.
#
# The lifecycle state remembers *configuration*, never command text: this
# library serializes the resolved persistent options of a run into a compact
# "option:value" record, and reconstructs the argument vector the current
# parser accepts from such a record. Nothing here executes stored text, and
# every remembered option is checked against the current option manifest, so a
# removed or renamed option fails loudly instead of quietly changing meaning.
#
# Transient execution controls (--dry-run, --non-interactive, --help, the
# development-workflow smoke tests) are deliberately absent from the manifest.
# They belong to a single invocation, not to the machine's configuration.

INSTALL_OPTION_MANIFEST="${INSTALL_OPTION_MANIFEST:-$DOTFILES_ROOT/config/install-options.tsv}"

# Version of the record encoding itself, recorded next to every selection.
# Bump it when the meaning of an existing encoded field changes; adding or
# removing manifest options is handled by the reconstruction rules below.
INSTALL_SELECTION_SCHEMA_VERSION=1

INSTALL_SELECTION_PLATFORM=""
declare -A INSTALL_SELECTION_VALUES=()

install_option_field_number() {
  case "$1" in
  platform) printf 1 ;; option) printf 2 ;; kind) printf 3 ;;
  on_flag) printf 4 ;; off_flag) printf 5 ;; default) printf 6 ;;
  values) printf 7 ;; capability) printf 8 ;; summary) printf 9 ;;
  *) return 1 ;;
  esac
}

install_option_field() {
  local platform="$1" option="$2" field="$3" number
  number="$(install_option_field_number "$field")" || return 1
  awk -F '\t' -v p="$platform" -v o="$option" -v n="$number" \
    'NR > 1 && $1 == p && $2 == o { print $n; found=1; exit } END { exit !found }' \
    "$INSTALL_OPTION_MANIFEST"
}

# Persistent options of a platform, in manifest order. That order is the
# serialization order too, so an unchanged selection serializes identically.
install_option_names() {
  local platform="$1"
  awk -F '\t' -v p="$platform" 'NR > 1 && $1 == p { print $2 }' \
    "$INSTALL_OPTION_MANIFEST"
}

install_option_exists() {
  install_option_field "$1" "$2" kind >/dev/null 2>&1
}

install_selection_value_is_valid() {
  local platform="$1" option="$2" value="$3" kind pattern
  kind="$(install_option_field "$platform" "$option" kind)" || return 1
  case "$kind" in
  boolean) [[ "$value" == true || "$value" == false ]] ;;
  tristate) [[ "$value" == true || "$value" == false || "$value" == inherit ]] ;;
  value)
    [[ "$value" != - ]] || return 0
    pattern="$(install_option_field "$platform" "$option" values)"
    [[ "$pattern" != - ]] || return 1
    [[ "$value" =~ ^($pattern)$ ]]
    ;;
  *) return 1 ;;
  esac
}

install_selection_reset() {
  local platform="$1"
  install_option_names "$platform" | grep -q . ||
    die "No persistent installer options are declared for platform: $platform"
  INSTALL_SELECTION_PLATFORM="$platform"
  INSTALL_SELECTION_VALUES=()
}

# Record one resolved persistent choice. Values are the resolved ones: an
# auto-detected or interactively answered option is stored as what it resolved
# to, because that is the configuration a rerun must reproduce.
install_selection_set() {
  local option="$1" value="$2"
  [[ -n "$INSTALL_SELECTION_PLATFORM" ]] ||
    die 'install_selection_set requires install_selection_reset first'
  install_option_exists "$INSTALL_SELECTION_PLATFORM" "$option" ||
    die "Unknown persistent installer option for $INSTALL_SELECTION_PLATFORM: $option"
  [[ -z "${INSTALL_SELECTION_VALUES[$option]+set}" ]] ||
    die "Duplicate persistent installer option: $option"
  install_selection_value_is_valid "$INSTALL_SELECTION_PLATFORM" "$option" "$value" ||
    die "Invalid value for persistent installer option $option: $value"
  INSTALL_SELECTION_VALUES["$option"]="$value"
}

# Serialize every declared option of the platform. A missing option is a
# programming error rather than a silent gap in the remembered configuration.
install_selection_serialize() {
  local option record=""
  [[ -n "$INSTALL_SELECTION_PLATFORM" ]] ||
    die 'install_selection_serialize requires install_selection_reset first'
  while IFS= read -r option; do
    [[ -n "${INSTALL_SELECTION_VALUES[$option]+set}" ]] ||
      die "Persistent installer option was never recorded: $option"
    record+="${record:+,}$option:${INSTALL_SELECTION_VALUES[$option]}"
  done < <(install_option_names "$INSTALL_SELECTION_PLATFORM")
  printf '%s\n' "$record"
}

install_selection_record_value() {
  local record="$1" wanted="$2" pair
  local -a pairs=()
  IFS=, read -r -a pairs <<<"$record"
  for pair in "${pairs[@]}"; do
    [[ "${pair%%:*}" == "$wanted" ]] || continue
    printf '%s\n' "${pair#*:}"
    return 0
  done
  return 1
}

# Reject anything the current checkout can no longer interpret. A remembered
# option that has been removed or renamed must stop a rerun: silently dropping
# it would reapply a different configuration than the one that was recorded.
install_selection_validate_record() {
  local platform="$1" record="$2" pair key seen_key
  local -a pairs=() seen=()
  [[ -n "$record" ]] || {
    printf 'Remembered configuration is empty.\n' >&2
    return 1
  }
  IFS=, read -r -a pairs <<<"$record"
  for pair in "${pairs[@]}"; do
    [[ "$pair" == *:* ]] || {
      printf 'Remembered configuration is corrupt near: %s\n' "$pair" >&2
      return 1
    }
    key="${pair%%:*}"
    install_option_exists "$platform" "$key" || {
      printf 'Remembered option "%s" no longer exists for platform %s.\n' \
        "$key" "$platform" >&2
      printf 'It was removed or renamed since the configuration was recorded; rerun refuses to guess what it meant.\n' >&2
      printf 'Run ./install.sh with the options you want once; that install records a configuration this checkout understands.\n' >&2
      return 1
    }
    for seen_key in "${seen[@]}"; do
      [[ "$seen_key" != "$key" ]] || {
        printf 'Remembered configuration repeats option: %s\n' "$key" >&2
        return 1
      }
    done
    seen+=("$key")
    install_selection_value_is_valid "$platform" "$key" "${pair#*:}" || {
      printf 'Remembered value for option %s is not valid in this checkout: %s\n' \
        "$key" "${pair#*:}" >&2
      return 1
    }
  done
}

# Reconstruct the current parser's input from a validated record, one argument
# per line. An option added after the record was written is reported and falls
# back to its manifest default rather than disappearing without a word.
install_selection_render_args() {
  local platform="$1" record="$2" option kind value on_flag off_flag
  install_selection_validate_record "$platform" "$record" || return 1
  while IFS= read -r option; do
    if ! value="$(install_selection_record_value "$record" "$option")"; then
      value="$(install_option_field "$platform" "$option" default)"
      printf 'NOTE: option --%s was added after this configuration was recorded; using its default (%s).\n' \
        "$option" "$value" >&2
    fi
    kind="$(install_option_field "$platform" "$option" kind)"
    on_flag="$(install_option_field "$platform" "$option" on_flag)"
    off_flag="$(install_option_field "$platform" "$option" off_flag)"
    case "$kind" in
    value)
      [[ "$value" == - ]] || printf '%s\n%s\n' "$on_flag" "$value"
      ;;
    boolean | tristate)
      case "$value" in
      true) [[ "$on_flag" == - ]] || printf '%s\n' "$on_flag" ;;
      false) [[ "$off_flag" == - ]] || printf '%s\n' "$off_flag" ;;
      esac
      ;;
    esac
  done < <(install_option_names "$platform")
}

# Human-readable one-line rendering of the reconstructed arguments.
install_selection_render_display() {
  local platform="$1" record="$2" argument rendered="" quoted reconstructed
  reconstructed="$(install_selection_render_args "$platform" "$record" 2>/dev/null)" ||
    return 1
  while IFS= read -r argument; do
    [[ -n "$argument" ]] || continue
    printf -v quoted '%q' "$argument"
    rendered+="${rendered:+ }$quoted"
  done <<<"$reconstructed"
  printf '%s\n' "$rendered"
}
