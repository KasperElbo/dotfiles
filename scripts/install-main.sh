#!/usr/bin/env bash

# This is the modern-Bash boundary. The compatibility entry point has already
# had an opportunity to establish Homebrew Bash before this guard runs.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ERROR: The real installer requires Bash 4.4 or newer (found %s).\n' \
    "$BASH_VERSION" >&2
  printf 'On macOS, start through ./install.sh --platform macos so the compatibility bootstrap can locate or install Homebrew Bash.\n' >&2
  exit 2
fi

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == doctor ]]; then
  shift
  exec "$BASH" "$repo_root/scripts/doctor.sh" "$@"
fi

platform="fedora"
default_platform="$platform"
platform_explicit=false
rerun=false
help_requested=false
forwarded_args=()

while (($#)); do
  case "$1" in
  --platform)
    [[ $# -ge 2 ]] || {
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    }
    platform="$2"
    platform_explicit=true
    shift 2
    ;;
  --platform=*)
    platform="${1#*=}"
    [[ -n "$platform" ]] || {
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    }
    platform_explicit=true
    shift
    ;;
  --rerun)
    rerun=true
    shift
    ;;
  *)
    forwarded_args+=("$1")
    shift
    ;;
  esac
done

for forwarded_arg in "${forwarded_args[@]}"; do
  [[ "$forwarded_arg" == -h || "$forwarded_arg" == --help ]] || continue
  help_requested=true
done

# --- --rerun: reapply the remembered configuration ---------------------------
#
# The remembered configuration is structured lifecycle state, and it is turned
# back into this parser's input by the common selection library. No stored
# command text is ever interpreted or executed, and only transient execution
# controls may accompany --rerun: mixing in configuration-changing options
# would silently merge two sources of truth for the same machine.
if [[ "$rerun" == true && "$help_requested" != true ]]; then
  # shellcheck source=../common/lib/common.sh
  source "$repo_root/common/lib/common.sh"
  # shellcheck source=../common/lib/install-lifecycle.sh
  source "$repo_root/common/lib/install-lifecycle.sh"

  transient_args=()
  for forwarded_arg in "${forwarded_args[@]}"; do
    case "$forwarded_arg" in
    --dry-run | --non-interactive)
      transient_args+=("$forwarded_arg")
      ;;
    *)
      printf 'ERROR: --rerun cannot be combined with %s\n' "$forwarded_arg" >&2
      printf '       --rerun reapplies the remembered configuration of the last successful install;\n' >&2
      printf '       a configuration-changing option would silently fight that record.\n' >&2
      printf '       Allowed with --rerun: --dry-run, --non-interactive, --platform (it must match\n' >&2
      printf '       the remembered platform), and -h/--help.\n' >&2
      printf '       Preview the remembered configuration with ./install.sh --rerun --dry-run, or run\n' >&2
      printf '       ./install.sh with your own options to install and record a new configuration.\n' >&2
      exit 1
      ;;
    esac
  done

  install_remembered_load || exit 1

  if [[ "$platform_explicit" == true && "$platform" != "$INSTALL_REMEMBERED_PLATFORM" ]]; then
    printf 'ERROR: the remembered configuration is for platform %s, but this run asked for %s.\n' \
      "$INSTALL_REMEMBERED_PLATFORM" "$platform" >&2
    printf '       Run ./install.sh --rerun to reapply it, or install %s explicitly with its own options.\n' \
      "$platform" >&2
    exit 1
  fi
  platform="$INSTALL_REMEMBERED_PLATFORM"

  if [[ ! -f "$repo_root/platforms/$platform/install.sh" ]]; then
    printf 'ERROR: the remembered configuration is for platform %s, which this checkout no longer provides.\n' \
      "$platform" >&2
    exit 1
  fi

  remembered_rendered="$(
    install_selection_render_args "$platform" "$INSTALL_REMEMBERED_SELECTION"
  )" || exit 1
  remembered_args=()
  while IFS= read -r remembered_arg; do
    [[ -n "$remembered_arg" ]] || continue
    remembered_args+=("$remembered_arg")
  done <<<"$remembered_rendered"

  printf '\nRemembered configuration (last successful install)\n'
  printf '%s\n' '-------------------------------------------------'
  printf 'Source:    %s (selection schema %s)\n' \
    "$(install_state_path)" "$INSTALL_SELECTION_SCHEMA_VERSION"
  printf 'Recorded:  %s\n' "$INSTALL_REMEMBERED_AT"
  printf 'Platform:  %s\n' "$platform"
  printf 'Options:   %s\n' \
    "$(install_selection_render_display "$platform" "$INSTALL_REMEMBERED_SELECTION")"
  if ((${#transient_args[@]} > 0)); then
    printf 'This run:  %s\n' "${transient_args[*]}"
  fi
  printf '\nThe recorded configuration is resolved by the installer in this checkout;\n'
  printf 'no stored command text is executed.\n'

  forwarded_args=("${remembered_args[@]}" "${transient_args[@]}")
fi

supported_platform_names=()
while IFS= read -r supported_platform_name; do
  supported_platform_names+=("$supported_platform_name")
done < <(awk -F '\t' 'NR > 1 && $1 == "base" && $15 == "implemented" {print $2}' \
  "$repo_root/config/capabilities.tsv" | sort -u)
supported_platforms="$(
  IFS='|'
  printf '%s' "${supported_platform_names[*]}"
)"

# The same list as prose, for the help text: one source, two renderings.
supported_platforms_sentence=""
for supported_platform_name in "${supported_platform_names[@]}"; do
  entry="$supported_platform_name"
  [[ "$supported_platform_name" != "$default_platform" ]] || entry+=" (default)"
  supported_platforms_sentence+="${supported_platforms_sentence:+, }$entry"
done
if ! awk -F '\t' -v platform="$platform" \
  'NR > 1 && $1 == "base" && $2 == platform && $15 == "implemented" {found=1} END {exit !found}' \
  "$repo_root/config/capabilities.tsv"; then
  printf 'ERROR: Unsupported platform: %s (expected one of %s)\n' \
    "$platform" "$supported_platforms" >&2
  exit 1
fi

print_platform_options() {
  local line
  local options_seen="false"

  while IFS= read -r line; do
    if [[ "$options_seen" == "true" ]]; then
      printf '%s\n' "$line"
    elif [[ "$line" == "Options:" ]]; then
      options_seen="true"
    fi
  done

  if [[ "$options_seen" != "true" ]]; then
    printf 'ERROR: Platform help did not contain an Options section.\n' >&2
    return 1
  fi
}

for forwarded_arg in "${forwarded_args[@]}"; do
  if [[ "$forwarded_arg" == "-h" || "$forwarded_arg" == "--help" ]]; then
    cat <<EOF
Usage: ./install.sh [--platform NAME|--platform=NAME] [options]
       ./install.sh --rerun [--dry-run] [--non-interactive]
       ./install.sh doctor

Options (platform '$platform'):
  --platform NAME    Target platform: selects which platforms/NAME/install.sh
                     runs; all other options below are that platform's own
                     and are simply forwarded to it. Available platforms:
                     $supported_platforms_sentence
  --rerun            Reapply this machine's last successful configuration.
                     The selection comes from the recorded lifecycle state
                     and is resolved by the installer in this checkout; no
                     stored command text is executed. Only --dry-run and
                     --non-interactive may accompany it, and they apply to
                     this run alone. Configuration-changing options are
                     rejected rather than merged with the remembered ones.
EOF
    "$BASH" "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}" |
      print_platform_options
    exit 0
  fi
done

exec "$BASH" "$repo_root/platforms/$platform/install.sh" "${forwarded_args[@]}"
