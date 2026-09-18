#!/usr/bin/env bash

# Selecting the supported Bash, for entry points that may start under Apple's.
#
# macOS ships Bash 3.2. Everything else in common/lib/ is written for the
# repository's documented Bash 4.4+ runtime and may use associative arrays,
# `mapfile` and the rest; `install-selection.sh` opens with `declare -A`, which
# under 3.2 fails at source time with `declare: -A: invalid option` before any
# of the command's own code runs.
#
# This file is therefore the one library deliberately limited to the 3.2
# dialect, because it is sourced *before* the interpreter has been chosen: no
# associative arrays, no `mapfile`, no `${name,,}` case conversion. `[[ ]]` and
# `(( ))` do exist in 3.2; the plain `[ ]` below is habit rather than necessity.
# It must stay inside that dialect. Nothing here uses lib/common.sh, so it also
# has no guard to source it.
#
# It selects an interpreter and nothing else. Installing one is the macOS
# compatibility bootstrap's job (scripts/bootstrap-macos.sh), which runs once,
# with the user's consent, as part of installation. A user command that
# installed Homebrew because it wanted to change a colour scheme would be a
# surprise, so when no supported Bash is present these functions report that
# and let the caller refuse.

MODERN_BASH_MINIMUM="4.4"

# modern_bash_is_supported <path>: whether that interpreter is 4.4 or newer.
modern_bash_is_supported() {
  [ -n "$1" ] || return 1
  [ -x "$1" ] || return 1
  "$1" -c \
    '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' \
    >/dev/null 2>&1
}

# modern_bash_find: print the path of a supported Bash, or nothing.
#
# The candidates, in order: the interpreter already running, whatever `bash`
# resolves to on PATH, and then the two Homebrew prefixes. Apple Silicon is the
# supported macOS profile, so /opt/homebrew comes first; /usr/local is a
# compatibility fallback for an Intel machine rather than a supported target.
# DOTFILES_MODERN_BASH names an interpreter explicitly, which is how the tests
# reach this without a second Bash installed.
modern_bash_find() {
  candidate=""
  for candidate in \
    "${DOTFILES_MODERN_BASH:-}" \
    "${BASH:-}" \
    "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash; do
    if modern_bash_is_supported "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# modern_bash_unavailable_message <command>: what to tell the user instead of
# `declare: -A: invalid option`, which names neither the cause nor the fix.
modern_bash_unavailable_message() {
  printf 'ERROR: %s requires Bash %s or newer (found %s).\n' \
    "$1" "$MODERN_BASH_MINIMUM" "${BASH_VERSION:-an unknown version}" >&2
  printf 'macOS ships Bash 3.2. The macOS profile installs a supported Bash:\n' >&2
  printf '  ./install.sh --platform macos\n' >&2
  printf 'or install one directly with: brew install bash\n' >&2
}

# modern_bash_reexec <command> <script> [argument...]: continue under a
# supported Bash, re-executing only when the current one is not.
#
# Returning rather than exiting when the running Bash is already supported is
# what keeps Linux behaviour unchanged: there the first candidate matches and
# no new process is created.
modern_bash_reexec() {
  modern_bash_command="$1"
  modern_bash_script="$2"
  shift 2

  if modern_bash_is_supported "${BASH:-}"; then
    return 0
  fi

  modern_bash_selected="$(modern_bash_find || true)"
  if [ -z "$modern_bash_selected" ]; then
    modern_bash_unavailable_message "$modern_bash_command"
    return 1
  fi

  if [ "${DOTFILES_BOOTSTRAP_TRACE:-false}" = "true" ]; then
    printf '%s: re-executing with %s\n' \
      "$modern_bash_command" "$modern_bash_selected" >&2
  fi
  exec "$modern_bash_selected" "$modern_bash_script" "$@"
}
