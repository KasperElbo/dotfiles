#!/usr/bin/env bash

# The one place a dependency's minimum version is stated, for a tool this
# repository's toolchain preflights.
#
# Two minimums sit outside it on purpose, and docs/testing.md says why: the
# Bash floor, decided before this library can be sourced, and the Fedora
# kernel floor, which belongs to the distribution.
#
# config/tool-floors.tsv holds one row per tool, read by column name through
# lib/manifest.sh, so the test runner, lint, the Neovim installer, the four
# verifiers and the documentation all resolve the same floor. A floor repeated
# in each of those drifts, which is what had happened: three documentation
# pages stated two different Neovim minimums and nothing enforced either one.
#
# The table states facts only -- a tool, its floor, why, and who enforces it.
# How to ask a tool its version is shell, below, because a probe stored as text
# in a manifest would have to be executed as text to be useful.
#
# This library deliberately does not select shell options. It needs
# DOTFILES_ROOT and version_at_least from lib/common.sh, and sources that
# itself when the caller has not.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
# shellcheck source=manifest.sh
source "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"

TOOL_FLOOR_MANIFEST="${TOOL_FLOOR_MANIFEST:-$DOTFILES_ROOT/config/tool-floors.tsv}"

# tool_floor <tool>: the declared minimum version. Fails when the tool has no
# row, so a mistyped name cannot silently mean "no floor at all".
tool_floor() {
  local tool="$1"
  local floor

  floor="$(manifest_field "$TOOL_FLOOR_MANIFEST" min_version tool "$tool")" || {
    printf 'No version floor is declared for %s in %s\n' \
      "$tool" "$TOOL_FLOOR_MANIFEST" >&2
    return 1
  }
  printf '%s\n' "$floor"
}

# tool_version <tool> [command...]: the version the tool reports, bare, as in
# "0.12.5". The command defaults to the tool itself; a caller that runs the
# tool through something else, such as `mise exec -- nvim`, passes that vector
# instead so the floor is checked against the executable that will really run.
tool_version() {
  local tool="$1"
  shift
  local reported
  local -a probe=()

  if (($# > 0)); then probe=("$@"); else probe=("$tool"); fi

  # Output is captured first and parsed second, so a probe that prints its
  # banner and then exits non-zero -- a wrapper that warns about something
  # unrelated, say -- still yields the version it reported. Parsing is done
  # with sed rather than `head` so nothing closes the pipe early under the
  # pipefail that every entry point sets.
  case "$tool" in
  nvim)
    reported="$("${probe[@]}" --version 2>/dev/null || true)"
    printf '%s\n' "$reported" |
      sed -n 's/^NVIM v\([0-9][0-9.]*\).*/\1/p' |
      sed -n 1p
    ;;
  python3)
    reported="$(
      "${probe[@]}" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' \
        2>/dev/null || true
    )"
    printf '%s\n' "$reported" |
      sed -n 's/^\([0-9][0-9.]*\)$/\1/p' |
      sed -n 1p
    ;;
  *)
    printf 'No version probe is defined for %s\n' "$tool" >&2
    return 1
    ;;
  esac
}

# tool_floor_check <tool> [command...]: refuse when the installed version is
# below the declared floor. The message names the tool, the version found and
# the floor, because the failure this replaces named none of the three.
tool_floor_check() {
  local tool="$1"
  shift
  local floor version manifest

  floor="$(tool_floor "$tool")" || return 1
  manifest="${TOOL_FLOOR_MANIFEST#"$DOTFILES_ROOT/"}"
  # A tool with no probe arm has already said so. Reporting it as a version
  # that did not parse would name the wrong reason for the refusal.
  version="$(tool_version "$tool" "$@")" || return 1

  [[ -n "$version" ]] || {
    printf '%s did not report a usable version; %s or newer is required (%s)\n' \
      "$tool" "$floor" "$manifest" >&2
    return 1
  }
  version_at_least "$version" "$floor" || {
    printf '%s %s is older than the required %s (%s)\n' \
      "$tool" "$version" "$floor" "$manifest" >&2
    return 1
  }
}
