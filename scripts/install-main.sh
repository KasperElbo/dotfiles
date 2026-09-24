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

# Found without dirname, for the reason given at the base bootstrap below.
script_dir="${BASH_SOURCE[0]%/*}"
[[ "$script_dir" != "${BASH_SOURCE[0]}" ]] || script_dir=.
repo_root="$(cd -- "$script_dir/.." && pwd)"

# The root command grammar, the same one the compatibility entry point states
# and for the same reason (#373):
#
#   ./install.sh [--platform NAME | --platform=NAME] doctor
#   ./install.sh [any platform options]
#
# doctor is a subcommand rather than a platform option, and it is not $1 alone
# because the macOS compatibility bootstrap forwards the original vector
# unchanged, so ./install.sh --platform macos doctor arrives here with the
# selector first. It is read in command position -- the first argument that is
# neither the --platform selector nor the value it consumes -- and nothing may
# follow it. Scanning the whole vector for the token instead let any option's
# value claim the subcommand, so ./install.sh --theme doctor --dry-run exited 0
# from the read-only report rather than reaching the platform installer that
# would have rejected doctor as a Catppuccin flavour. --platform doctor still
# names a (nonexistent) platform and is reported as one, because the selector
# consumes it before command position is reached.
subcommand=""
subcommand_trailing=()
command_position_taken=false
scan_expect_platform=false
for argument in "$@"; do
  if [[ "$command_position_taken" == true ]]; then
    subcommand_trailing+=("$argument")
    continue
  fi
  if [[ "$scan_expect_platform" == true ]]; then
    scan_expect_platform=false
    continue
  fi
  case "$argument" in
  --platform) scan_expect_platform=true ;;
  --platform=*) ;;
  doctor)
    subcommand="doctor"
    command_position_taken=true
    ;;
  *) command_position_taken=true ;;
  esac
done

if [[ "$subcommand" == doctor ]]; then
  # The report takes no arguments of its own, so anything after it was meant
  # for something else and is reported rather than dropped in silence.
  if ((${#subcommand_trailing[@]} > 0)); then
    printf 'ERROR: doctor takes no arguments (got %s)\n' \
      "${subcommand_trailing[0]}" >&2
    printf 'Usage: ./install.sh [--platform NAME] doctor\n' >&2
    exit 1
  fi
  exec "$BASH" "$repo_root/scripts/doctor.sh"
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

# The base bootstrap comes before the first manifest read, because that read is
# awk and a fresh Fedora WSL distro has none: it installs, with dnf, whatever
# the installer runs before its own package step and this machine lacks, and
# prints nothing on a machine that has it all. It is registry-driven, so a
# platform without bootstrap-package rows in config/command-providers.tsv
# passes straight through; the Fedora installers call it again for their direct
# entry points, where it finds nothing left to do. Everything above this line
# is Bash alone -- the --rerun branch aside, which reads the record of an
# install that already established these packages.
# shellcheck source=../common/lib/base-bootstrap.sh
source "$repo_root/common/lib/base-bootstrap.sh"
base_bootstrap "$platform" "${forwarded_args[@]}"

# The supported names are config/capabilities.tsv's implemented base rows that
# this entry point can actually run, read by column name (see
# common/lib/manifest.sh). A header that lacks a column stops here, naming it,
# instead of reporting no supported platforms. The manifest registers one
# platform more than this list: the Windows host has a base row, a provider and
# a verifier, but its installer is platforms/windows/install.ps1, so the exec
# below would name a script that does not exist. Requiring that script here is
# what keeps "supported" meaning "runnable from here" (scripts/lib/manifests.py
# draws the same line for the generators).
# shellcheck source=../common/lib/manifest.sh
source "$repo_root/common/lib/manifest.sh"
supported_platform_rows="$(manifest_values \
  "${CAPABILITY_MANIFEST:-$repo_root/config/capabilities.tsv}" platform \
  capability base status implemented)" || exit 1
supported_platform_names=()
while IFS= read -r supported_platform_name; do
  [[ -f "$repo_root/platforms/$supported_platform_name/install.sh" ]] || continue
  supported_platform_names+=("$supported_platform_name")
done < <(printf '%s\n' "$supported_platform_rows" | sed '/^$/d' | sort -u)
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
platform_supported=false
for supported_platform_name in "${supported_platform_names[@]}"; do
  [[ "$supported_platform_name" != "$platform" ]] || platform_supported=true
done
if [[ "$platform_supported" != true ]]; then
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
       ./install.sh [--platform NAME] doctor

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
