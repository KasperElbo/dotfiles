#!/usr/bin/env bash

# Named, independently-isolated theme actions (issue #148).
#
# Applying a theme is a set of mostly independent effects: shared state files,
# a tmux reload, a desktop theme, a terminal notice. Before this, one failing
# effect aborted every later one *after* state had already changed, and the
# command still reported a complete application.
#
# Every effect now runs through a named action with its own error boundary. An
# independent action that fails is reported and recorded but does not stop the
# others; a required action that fails stops the command, because nothing after
# it would be meaningful. The overall result is nonzero whenever anything
# failed, and the summary names what applied and what did not.
#
# Results are accumulated in a file rather than in shell arrays: hooks run in
# subshells so one hook cannot corrupt the next, and a subshell's array
# assignments would be lost. The log is the one place every boundary can
# report through, and it stays behind afterwards as a record of what the last
# theme application actually did.
#
# Reading and writing it uses only shell builtins, so the reporting path adds
# no external command of its own to a command that must work on a very small
# PATH.

THEME_ACTION_LOG="${THEME_ACTION_LOG:-}"

theme_actions_begin() {
  local log="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/theme-actions.log"

  mkdir -p "${log%/*}" || return 1
  : >"$log" || return 1

  THEME_ACTION_LOG="$log"
  export THEME_ACTION_LOG
}

_theme_record() {
  local kind="$1" name="$2" detail="${3:-}"
  [[ -n "$THEME_ACTION_LOG" ]] || return 0
  printf '%s\t%s\t%s\n' "$kind" "$name" "$detail" >>"$THEME_ACTION_LOG"
}

_theme_names() {
  local wanted="$1" kind name detail
  [[ -n "$THEME_ACTION_LOG" && -r "$THEME_ACTION_LOG" ]] || return 0
  while IFS=$'\t' read -r kind name detail; do
    [[ "$kind" == "$wanted" ]] || continue
    if [[ -n "$detail" ]]; then
      printf '%s (%s)\n' "$name" "$detail"
    else
      printf '%s\n' "$name"
    fi
  done <"$THEME_ACTION_LOG"
}

_theme_print_list() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  - %s\n' "$line"
  done <<<"$1"
}

# _theme_isolated <command> [arguments...]
#
# The error boundary itself: run a command in a subshell and leave its exit
# status in _theme_status. The subshell keeps a hook's `set -e`, `exit`, `cd` or
# stray variable from reaching the actions that follow it.
#
# The subshell must never be the left side of `||`, or the condition of `if` or
# `!`. Bash ignores errexit for everything a command in such a context runs,
# however deep and even after an explicit `set -e`, so a hook whose first
# statement failed would run on and be reported as applied. Instead errexit is
# off in this shell only while the subshell runs, and the subshell turns it
# back on for itself when the caller had it. The boundaries hold only when
# they are themselves called as plain statements.
_theme_isolated() {
  local errexit=false
  [[ "$-" != *e* ]] || errexit=true

  set +e
  (
    [[ "$errexit" != true ]] || set -e
    "$@"
  )
  _theme_status=$?
  [[ "$errexit" != true ]] || set -e
  return 0
}

# theme_action <name> <command> [arguments...]
#
# One independent action inside its own error boundary. Always returns 0 so an
# errexit caller continues with the remaining independent actions; the failure
# is recorded and reported instead.
theme_action() {
  local name="$1"
  shift

  theme_action_or_skip "$name" '' '' "$@"
}

# theme_action_or_skip <name> <skip-status> <reason> <command> [arguments...]
#
# theme_action, plus one exit status the command uses to say the thing it acts
# on is not installed. That outcome is recorded with theme_action_skipped and
# the given reason; every other status is recorded exactly as theme_action
# records it.
#
# It exists because applied and failed are not the only outcomes an action can
# have. One that reaches another system has a third: the other half is not
# there yet. Without a status to say so, that case is indistinguishable from
# an application -- the command ran, found nothing to do, and exited 0 -- and
# the summary reports a flavour as applied where nothing was applied. A hook
# cannot correct that after the fact, because theme_action has already
# recorded the run by the time it returns.
#
# An empty skip-status means there is no such outcome, which is what
# theme_action passes.
theme_action_or_skip() {
  local name="$1" skip_status="$2" skip_reason="$3"
  shift 3
  local _theme_status=0 status

  _theme_isolated "$@"
  status="$_theme_status"

  if [[ -n "$skip_status" ]] && ((status == skip_status)); then
    theme_action_skipped "$name" "$skip_reason"
    return 0
  fi

  if ((status == 0)); then
    _theme_record applied "$name"
  else
    _theme_record failed "$name" "exit $status"
    printf 'theme: action "%s" failed (exit %s); continuing with independent actions.\n' \
      "$name" "$status" >&2
  fi

  return 0
}

# theme_action_required <name> <command> [arguments...]
#
# For an action whose output everything else depends on. A failure here is
# fatal: continuing would leave the machine claiming a theme it does not have.
# Returns 1 on failure, having printed the action's own exit status, so an
# errexit caller that runs it as a plain statement stops with status 1.
theme_action_required() {
  local name="$1"
  shift
  local _theme_status=0 status

  # Isolated like an independent action so that an errexit failure inside it
  # is reported through this boundary instead of killing the command before it
  # can say which action failed.
  _theme_isolated "$@"
  status="$_theme_status"

  if ((status == 0)); then
    _theme_record applied "$name"
    return 0
  fi

  _theme_record failed "$name" "exit $status"
  printf 'theme: required action "%s" failed (exit %s); stopping.\n' \
    "$name" "$status" >&2
  return 1
}

# theme_action_skipped <name> <reason>
#
# Records an action deliberately not run, so a capability that is not installed
# stays visibly distinct from one that failed.
theme_action_skipped() {
  _theme_record skipped "$1" "$2"
}

# A hook is a boundary around other actions rather than an action itself: it is
# recorded only when the hook body itself fails, so its own named sub-actions
# are what the summary lists.
theme_hook() {
  local name="$1"
  shift
  local _theme_status=0 status

  _theme_isolated "$@"
  status="$_theme_status"

  if ((status != 0)); then
    _theme_record failed "$name" "exit $status"
    printf 'theme: hook "%s" failed (exit %s); continuing with other hooks.\n' \
      "$name" "$status" >&2
  fi

  return 0
}

# A hook that owns the Ghostty message says so, and the portable command then
# does not print its own generic guidance.
theme_note_ghostty_handled() {
  _theme_record flag ghostty-handled
}

theme_ghostty_handled() {
  local kind name detail
  [[ -n "$THEME_ACTION_LOG" && -r "$THEME_ACTION_LOG" ]] || return 1
  while IFS=$'\t' read -r kind name detail; do
    [[ "$kind" == flag && "$name" == ghostty-handled ]] || continue
    return 0
  done <"$THEME_ACTION_LOG"
  return 1
}

theme_actions_failed() {
  [[ -n "$(_theme_names failed)" ]]
}

# Print what actually happened. Never claims a theme is fully applied when
# something the user can see did not change.
theme_actions_report() {
  local flavour="$1" skipped applied failed
  skipped="$(_theme_names skipped)"
  applied="$(_theme_names applied)"
  failed="$(_theme_names failed)"

  if [[ -n "$skipped" ]]; then
    printf '\nNot applicable on this machine:\n'
    _theme_print_list "$skipped"
  fi

  if [[ -z "$failed" ]]; then
    printf '\nCatppuccin %s selected.\n' "$flavour"
    return 0
  fi

  printf '\nCatppuccin %s was applied only partially.\n' "$flavour" >&2
  printf 'Applied:\n' >&2
  _theme_print_list "${applied:-none}" >&2
  printf 'Failed:\n' >&2
  _theme_print_list "$failed" >&2
  printf 'Fix the cause and run "theme %s" again; the shared theme state is already current.\n' \
    "$flavour" >&2
  return 1
}

# --- Capability awareness ---------------------------------------------------
#
# A hook must not apply identifiers for assets that were never installed:
# a Fedora machine installed with `--no-kde` has no Catppuccin KDE themes, so
# applying the KDE global theme would name a theme that does not exist.
#
# The installed capability set is the authoritative answer and comes from the
# install lifecycle state, through that library's own helper — this adds no
# second store. "No recorded installation" is deliberately a third answer: on
# such a machine the caller falls back to looking for the assets themselves,
# which is what makes a pre-lifecycle machine behave sensibly instead of
# refusing everything.

# True when the capability was selected, or when this machine has no readable
# install state to consult. False only when the state positively records the
# capability as not installed.
theme_capability_permits() {
  local capability="$1" status=0

  install_lifecycle_capability_selected "$capability" || status=$?
  case "$status" in
  1) return 1 ;;
  *) return 0 ;;
  esac
}

# True only when the install state positively records the capability as absent.
theme_capability_known_absent() {
  local capability="$1" status=0

  install_lifecycle_capability_selected "$capability" || status=$?
  ((status == 1))
}
