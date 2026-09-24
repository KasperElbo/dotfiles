#!/bin/bash

# Compatibility entry point. Keep this file within Apple's Bash 3.2 syntax:
# the real installer starts only after the macOS bootstrap has found or
# established the repository's supported Bash.
set -e

# Found without dirname: on a minimal Fedora image coreutils may be one of the
# packages the base bootstrap (common/lib/base-bootstrap.sh) has yet to install,
# so nothing on the way to it may need more than Bash and its prerequisites.
case "$0" in
  */*) repo_root="${0%/*}" ;;
  *) repo_root="." ;;
esac
repo_root="$(cd "$repo_root" && pwd)"
platform="fedora"
platform_explicit="false"
rerun="false"
expect_platform="false"
help_requested="false"

# Inspect only the platform selector, --rerun and the help flags. Do not shift
# or rebuild "$@": the exact original argument vector is forwarded across the
# interpreter boundary. The platform selector is honoured wherever it stands,
# because every other option here belongs to the platform installer and may
# precede it; the doctor subcommand is not read in this loop, for the reason
# the grammar below states.
for argument in "$@"; do
  if [ "$expect_platform" = "true" ]; then
    if [ -z "$argument" ]; then
      printf 'ERROR: --platform requires a value\n' >&2
      exit 1
    fi
    platform="$argument"
    platform_explicit="true"
    expect_platform="false"
    continue
  fi

  case "$argument" in
    --platform)
      expect_platform="true"
      ;;
    --platform=*)
      platform="${argument#*=}"
      platform_explicit="true"
      if [ -z "$platform" ]; then
        printf 'ERROR: --platform requires a value\n' >&2
        exit 1
      fi
      ;;
    --rerun)
      rerun="true"
      ;;
    -h | --help)
      help_requested="true"
      ;;
  esac
done

if [ "$expect_platform" = "true" ]; then
  printf 'ERROR: --platform requires a value\n' >&2
  exit 1
fi

# The root command grammar, in one place (#373):
#
#   ./install.sh [--platform NAME | --platform=NAME] doctor
#   ./install.sh [any platform options]
#
# doctor is a word in command position, not a value that happens to spell it.
# Command position is the first argument that is neither the --platform
# selector nor the value it consumes, and nothing may follow the subcommand.
# Scanning the whole vector for the token instead -- which is what this did --
# made ./install.sh --theme doctor --dry-run exit 0 from the read-only report
# while the user was asking a platform installer for a Catppuccin flavour.
# Every argument here is either an option this file knows, or a platform option
# whose values this file cannot enumerate, so the only safe reading is
# positional.
subcommand=""
subcommand_trailing=""
subcommand_has_trailing="false"
command_position_taken="false"
scan_expect_platform="false"
for argument in "$@"; do
  if [ "$command_position_taken" = "true" ]; then
    if [ "$subcommand_has_trailing" = "false" ]; then
      subcommand_trailing="$argument"
      subcommand_has_trailing="true"
    fi
    continue
  fi

  if [ "$scan_expect_platform" = "true" ]; then
    scan_expect_platform="false"
    continue
  fi

  case "$argument" in
    --platform)
      scan_expect_platform="true"
      ;;
    --platform=*) ;;
    doctor)
      subcommand="doctor"
      command_position_taken="true"
      ;;
    *)
      command_position_taken="true"
      ;;
  esac
done

# The report takes no arguments of its own, so anything after it was meant for
# something else and is reported rather than dropped in silence.
if [ "$subcommand" = "doctor" ] && [ "$subcommand_has_trailing" = "true" ]; then
  printf 'ERROR: doctor takes no arguments (got %s)\n' "$subcommand_trailing" >&2
  printf 'Usage: ./install.sh [--platform NAME] doctor\n' >&2
  exit 1
fi

# The report is answered here, before the platform dispatch, however the
# optional selector is spelled. Routing it into a platform installer is what
# made ./install.sh --platform macos doctor answer with an unknown-option error
# from that platform's parser.
#
# It does not go through the macOS compatibility bootstrap either. That
# bootstrap exists to install Homebrew and a supported Bash, and the report is
# read-only; scripts/doctor.sh selects a supported interpreter for itself and
# says so plainly when there is none.
if [ "$subcommand" = "doctor" ]; then
  exec "${BASH:-/bin/bash}" "$repo_root/scripts/doctor.sh"
fi

# Help that names no platform describes the platform of the machine asking.
# The fedora default suits an installation, but on a Mac it sends the request
# to scripts/install-main.sh under Apple's Bash 3.2, whose Bash 4.4 gate then
# answers with an interpreter error instead of help. The macOS compatibility
# bootstrap is already the read-only answer for this machine: it shows the
# real installer's help when a supported Bash exists and its own macOS help
# otherwise, and --help never installs Homebrew or Bash. The selector is
# prepended because the bootstrap forwards the vector to the real installer,
# which would otherwise fall back to fedora itself. An explicit --platform
# always wins and takes the ordinary dispatch below.
if [ "$help_requested" = "true" ] && [ "$platform_explicit" = "false" ] &&
  [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  exec /bin/bash "$repo_root/scripts/bootstrap-macos.sh" --platform macos "$@"
fi

# A --rerun that names no platform must still reach the interpreter its
# remembered platform needs, so read just the recorded platform name here. The
# authoritative reading, validation and reconstruction of the remembered
# configuration belong to scripts/install-main.sh; this only chooses a boot
# path, and only for a name the repository actually provides.
if [ "$rerun" = "true" ] && [ "$platform_explicit" = "false" ]; then
  install_state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/install.conf"
  if [ -r "$install_state" ]; then
    remembered_platform="$(awk -F= \
      '$1 == "last_successful_platform" { print $2; exit }' "$install_state")"
    # The supported names live in config/capabilities.tsv, as its implemented
    # base rows that this repository has an installer script for. Asking the
    # manifest here keeps this guard from drifting away from the list
    # scripts/install-main.sh validates against, and requiring the script keeps
    # both from accepting a platform installed by something other than Bash
    # (the Windows host, installed by platforms/windows/install.ps1). Columns
    # are found by name in the header, as common/lib/manifest.sh does; this
    # entry point runs before a supported Bash exists, so it cannot source it.
    if [ -n "$remembered_platform" ] &&
      [ -f "$repo_root/platforms/$remembered_platform/install.sh" ] &&
      awk -F '\t' -v p="$remembered_platform" \
      'NR == 1 { for (i = 1; i <= NF; i++) column[$i] = i; next }
       column["capability"] && column["platform"] && column["status"] &&
       $column["capability"] == "base" && $column["platform"] == p &&
       $column["status"] == "implemented" { found = 1 }
       END { exit !found }' "$repo_root/config/capabilities.tsv" 2>/dev/null; then
      platform="$remembered_platform"
    fi
  fi
fi

if [ "$platform" = "macos" ]; then
  exec /bin/bash "$repo_root/scripts/bootstrap-macos.sh" "$@"
fi

exec "${BASH:-/bin/bash}" "$repo_root/scripts/install-main.sh" "$@"
