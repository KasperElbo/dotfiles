#!/usr/bin/env bash

# The Fedora base bootstrap: install, with dnf, the packages the installer
# itself runs before its base package step, when the image lacks them.
#
# A fresh Fedora WSL distro has no awk, and the installer reads every manifest
# under config/ with it -- its own list of base packages included -- so it died
# with "awk: command not found" before it could install gawk. awk is not the
# only one: config/command-providers.tsv classifies as `bootstrap-package`
# every command the installer runs before that step (the manifest reader, the
# plan, preflight, the lifecycle record), and this installs the provider of
# any of them the machine does not have. It is the Fedora counterpart of
# scripts/bootstrap-macos.sh, and outside the installation lifecycle for the
# same reason: the lifecycle is written with the commands it establishes.
#
# So this file may use nothing but Bash builtins and the bootstrap
# prerequisites (sudo and dnf here): not common.sh, which resolves the checkout
# with dirname, and not manifest.sh, which is awk. The manifest is read with
# Bash below, by column name as manifest.sh does. On a machine that already has
# every package it is a read of one manifest and prints nothing, so a full
# machine installs exactly as it did before this existed.
#
# A package is judged by its commands: it is missing when none of the commands
# it provides can be found. One command absent from a package that is
# otherwise installed is not something reinstalling it would fix; preflight
# names that command instead.

# base_bootstrap <platform> [installer argument]...
#
# Return when nothing is missing, or once the missing packages are installed.
# Every other outcome ends the process, as the platform parsers do: --dry-run
# prints this bootstrap's plan and exits 0 (the full plan needs these
# commands), a declined prompt exits 0 having changed nothing, and a refusal
# or a failed install exits 1. --help never changes the machine.
base_bootstrap() {
  local platform="$1"
  shift
  local manifest="${COMMAND_PROVIDER_MANIFEST:-$_BASE_BOOTSTRAP_ROOT/config/command-providers.tsv}"
  local mode=apply interactive=true argument
  for argument in "$@"; do
    case "$argument" in
    -h | --help) mode=help ;;
    --dry-run)
      [[ "$mode" == help ]] || mode=dry-run
      interactive=false
      ;;
    --non-interactive) interactive=false ;;
    esac
  done

  _base_bootstrap_read "$manifest" "$platform" || exit 1

  local provider command found missing_providers=() missing_commands=() provided=()
  for provider in "${_BASE_BOOTSTRAP_PROVIDERS[@]}"; do
    read -r -a provided <<<"${_BASE_BOOTSTRAP_COMMANDS[$provider]}"
    found=false
    for command in "${provided[@]}"; do
      ! type -P -- "$command" >/dev/null || found=true
    done
    [[ "$found" == false ]] || continue
    missing_providers+=("$provider")
    missing_commands+=("${provided[@]}")
  done
  ((${#missing_providers[@]} > 0)) || return 0

  local absent_prerequisites=() row
  for row in "${_BASE_BOOTSTRAP_PREREQUISITES[@]}"; do
    type -P -- "${row%%$'\t'*}" >/dev/null ||
      absent_prerequisites+=("Missing bootstrap-prerequisite command: ${row%%$'\t'*} (provider: ${row#*$'\t'})")
  done

  case "$mode" in
  help)
    printf 'The %s installer needs %s before it can show its help, and this machine does not have %s yet.\n' \
      "$platform" "$(_base_bootstrap_words "${missing_providers[@]}")" \
      "$(_base_bootstrap_words "${missing_commands[@]}")" >&2
    printf 'Run it with --dry-run to see what the bootstrap would install; --help changes nothing.\n' >&2
    exit 1
    ;;
  dry-run)
    printf '\nFedora base bootstrap plan\n'
    printf '%s\n' '--------------------------'
    printf 'The installer runs these commands before its own package step, and this\n'
    printf 'machine does not have them: %s.\n' "$(_base_bootstrap_words "${missing_commands[@]}")"
    printf 'Before anything else, the same command without --dry-run would run:\n\n'
    printf '  sudo dnf install -y %s\n\n' "${missing_providers[*]}"
    ((${#absent_prerequisites[@]} == 0)) || printf '%s\n' "${absent_prerequisites[@]}" ""
    printf 'The bootstrap is outside the installation lifecycle, because that lifecycle\n'
    printf 'is written with these commands. Once they exist, the same command renders\n'
    printf 'the complete installation plan. No changes were made.\n'
    exit 0
    ;;
  esac

  if ((${#absent_prerequisites[@]} > 0)); then
    printf '%s\n' "${absent_prerequisites[@]}" >&2
    printf 'Install them and rerun; nothing has been changed.\n' >&2
    exit 1
  fi
  _base_bootstrap_require_fedora || exit 1

  printf 'The installer needs %s before its own package step, and this machine does not have %s.\n' \
    "$(_base_bootstrap_words "${missing_providers[@]}")" \
    "$(_base_bootstrap_words "${missing_commands[@]}")"
  printf 'The Fedora base bootstrap installs them first: sudo dnf install -y %s\n' \
    "${missing_providers[*]}"
  if [[ "$interactive" == true ]]; then
    local answer
    # Asked the way common.sh's confirm asks, which cannot be sourced yet: the
    # prompt goes to the transcript whether or not stdin is a terminal, and a
    # closed stdin is a decline rather than an inherited yes.
    printf 'Install them now? [Y/n] ' >&2
    if ! read -r answer; then
      printf '\nNo answer is available on standard input; treating the prompt as declined.\n' >&2
      answer=n
    fi
    case "$answer" in
    '' | y | Y | yes | YES) ;;
    n | N | no | NO)
      printf 'Cancelled; no changes made.\n'
      exit 0
      ;;
    *)
      printf 'Invalid confirmation response: %s\n' "$answer" >&2
      exit 1
      ;;
    esac
  elif ! sudo -n -v; then
    printf "Non-interactive installation requires cached sudo authorization; run 'sudo -v' first.\n" >&2
    exit 1
  fi

  sudo dnf install -y "${missing_providers[@]}" || {
    printf 'The bootstrap packages did not install (%s); the installer did not start.\n' \
      "${missing_providers[*]}" >&2
    exit 1
  }
  hash -r
  local still_missing=()
  for command in "${missing_commands[@]}"; do
    type -P -- "$command" >/dev/null || still_missing+=("$command")
  done
  if ((${#still_missing[@]} > 0)); then
    printf 'dnf installed %s, but %s still cannot be found on PATH.\n' \
      "${missing_providers[*]}" "$(_base_bootstrap_words "${still_missing[@]}")" >&2
    exit 1
  fi
  printf 'Installed %s; starting the installer.\n' "${missing_providers[*]}"
}

# The checkout this file belongs to, found without dirname.
_BASE_BOOTSTRAP_ROOT="${BASH_SOURCE[0]%/*}"
[[ "$_BASE_BOOTSTRAP_ROOT" != "${BASH_SOURCE[0]}" ]] || _BASE_BOOTSTRAP_ROOT=.
_BASE_BOOTSTRAP_ROOT="$(cd -- "$_BASE_BOOTSTRAP_ROOT/../.." && pwd)"

# _base_bootstrap_words <word>...: the words joined by ", ", each once.
_base_bootstrap_words() {
  local word joined="" seen=" "
  for word in "$@"; do
    [[ "$seen" != *" $word "* ]] || continue
    seen+="$word "
    joined+="${joined:+, }$word"
  done
  printf '%s' "$joined"
}

# _base_bootstrap_split <line>: the line's tab-separated fields, empty ones
# kept, in _BASE_BOOTSTRAP_FIELDS. `read -a` with IFS=$'\t' would merge
# adjacent tabs, tab being IFS whitespace, and shift every later column.
_base_bootstrap_split() {
  local rest="$1"
  _BASE_BOOTSTRAP_FIELDS=()
  while [[ "$rest" == *$'\t'* ]]; do
    _BASE_BOOTSTRAP_FIELDS+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  _BASE_BOOTSTRAP_FIELDS+=("$rest")
}

# _base_bootstrap_read <manifest> <platform>: the platform's rows, in manifest
# order: _BASE_BOOTSTRAP_PROVIDERS lists each bootstrap-package provider once,
# _BASE_BOOTSTRAP_COMMANDS maps it to its commands, and
# _BASE_BOOTSTRAP_PREREQUISITES holds "command<TAB>provider" for each
# bootstrap-prerequisite. Columns are found by name, and a row that does not
# carry every column fails, as common/lib/manifest.sh holds them.
_base_bootstrap_read() {
  local manifest="$1" platform="$2" line number=0 width=0 name index
  local command provider
  local -A column=()
  _BASE_BOOTSTRAP_PROVIDERS=()
  _BASE_BOOTSTRAP_PREREQUISITES=()
  declare -gA _BASE_BOOTSTRAP_COMMANDS=()

  [[ -r "$manifest" ]] || {
    printf 'Command provider manifest is not readable: %s\n' "$manifest" >&2
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    _base_bootstrap_split "$line"
    if ((number == 1)); then
      for index in "${!_BASE_BOOTSTRAP_FIELDS[@]}"; do
        column[${_BASE_BOOTSTRAP_FIELDS[index]}]="$index"
      done
      for name in platform command provider classification; do
        [[ -n "${column[$name]:-}" ]] || {
          printf 'Manifest %s has no column: %s\n' "$manifest" "$name" >&2
          return 1
        }
      done
      width="${#_BASE_BOOTSTRAP_FIELDS[@]}"
      continue
    fi
    ((${#_BASE_BOOTSTRAP_FIELDS[@]} == width)) || {
      printf 'Manifest %s line %d: %d columns, expected %d\n' \
        "$manifest" "$number" "${#_BASE_BOOTSTRAP_FIELDS[@]}" "$width" >&2
      return 1
    }
    [[ "${_BASE_BOOTSTRAP_FIELDS[column[platform]]}" == "$platform" ]] || continue
    command="${_BASE_BOOTSTRAP_FIELDS[column[command]]}"
    provider="${_BASE_BOOTSTRAP_FIELDS[column[provider]]}"
    case "${_BASE_BOOTSTRAP_FIELDS[column[classification]]}" in
    bootstrap-package)
      [[ -n "${_BASE_BOOTSTRAP_COMMANDS[$provider]:-}" ]] ||
        _BASE_BOOTSTRAP_PROVIDERS+=("$provider")
      _BASE_BOOTSTRAP_COMMANDS[$provider]+="${_BASE_BOOTSTRAP_COMMANDS[$provider]:+ }$command"
      ;;
    bootstrap-prerequisite)
      _BASE_BOOTSTRAP_PREREQUISITES+=("$command"$'\t'"$provider")
      ;;
    esac
  done <"$manifest"
  ((number > 0)) || {
    printf 'Manifest %s is empty: it has no header row.\n' "$manifest" >&2
    return 1
  }
}

# The provider names are Fedora package names, so nothing is installed on a
# machine that is not Fedora; the platform installers refuse it afterwards
# with their own message.
_base_bootstrap_require_fedora() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}" key value os_id=""
  [[ -r "$os_release_file" ]] || {
    printf 'Cannot read %s\n' "$os_release_file" >&2
    return 1
  }
  while IFS='=' read -r key value; do
    [[ "$key" == ID ]] || continue
    os_id="${value#\"}"
    os_id="${os_id%\"}"
    break
  done <"$os_release_file"
  [[ "$os_id" == fedora ]] || {
    printf 'This installer supports Fedora only; nothing has been installed.\n' >&2
    return 1
  }
}
