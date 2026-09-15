#!/usr/bin/env bash

# One-time deprecation notices for compatibility entry points.
#
# A wrapper that still works is worth keeping while people's scripts and notes
# still name it; a wrapper that disappears without warning is not. Everything
# deprecated here keeps forwarding unchanged, and says once — on stderr, so it
# never corrupts a caller's stdout — what to use instead and when it goes away.
#
# Set DOTFILES_SUPPRESS_DEPRECATION=1 to silence the notice in scripted use.

# The date before which no deprecated wrapper is removed. It is a single
# constant so the window is one decision, visible in one place, rather than a
# date copied into thirty files.
DOTFILES_DEPRECATION_REMOVAL_DATE="2027-03-15"

# deprecated_wrapper <this-path> <supported-replacement> [direct-path]
#
# <supported-replacement> is what a user should type instead — normally the
# portable installer with the option that owns this component. [direct-path] is
# the platform-specific script this wrapper forwards to, for a caller who
# deliberately wants that one component and knows which platform they are on.
deprecated_wrapper() {
  local wrapper="$1"
  local replacement="$2"
  local direct="${3:-}"

  [[ "${DOTFILES_SUPPRESS_DEPRECATION:-0}" != "1" ]] || return 0

  printf '\033[1;33mDEPRECATED:\033[0m %s is a compatibility wrapper.\n' \
    "$wrapper" >&2
  printf '            Use %s instead.\n' "$replacement" >&2
  if [[ -n "$direct" ]]; then
    printf '            For this component alone, run %s.\n' "$direct" >&2
  fi
  printf '            It keeps working, and is removed no earlier than %s.\n' \
    "$DOTFILES_DEPRECATION_REMOVAL_DATE" >&2
}
