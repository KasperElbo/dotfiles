#!/usr/bin/env bash

# Lightweight ordered plan shared by dry-run, preflight and apply.
# Callers register shell function names, keeping component scripts independently
# useful while eliminating a second hand-maintained dry-run orchestration.
#
# It needs DOTFILES_ROOT, ensure_dir and the reporting helpers from
# lib/common.sh, and sources that itself, so it is correct sourced standalone.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

PLAN_IDS=()
PLAN_LABELS=()
PLAN_PHASES=()
PLAN_PREFLIGHTS=()
PLAN_APPLIES=()
PLAN_NOTES=()
PLAN_SCRIPTS=()
PLAN_COMPLETED=()
PLAN_COUNT=0
PLAN_COMPLETED_COUNT=0
PLAN_CURRENT_INDEX=-1

plan_log() {
  [[ -n "${DOTFILES_PLAN_LOG:-}" ]] || return 0
  ensure_dir "$(dirname "$DOTFILES_PLAN_LOG")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$DOTFILES_PLAN_LOG"
  chmod 600 "$DOTFILES_PLAN_LOG"
}

plan_reset() {
  PLAN_IDS=(); PLAN_LABELS=(); PLAN_PHASES=(); PLAN_PREFLIGHTS=()
  PLAN_APPLIES=(); PLAN_NOTES=(); PLAN_SCRIPTS=()
  PLAN_COMPLETED=()
  PLAN_COUNT=0; PLAN_COMPLETED_COUNT=0; PLAN_CURRENT_INDEX=-1
}

# The seventh field is the repository scripts the step runs, space-separated
# and relative to the checkout, or the empty string for a step that runs none.
#
# It is what the network preflight derives its probe set from: a source in
# config/network-sources.tsv is probed when a step that runs one of its
# consumers is in the resolved plan. A step could declare this wrongly, so
# scripts/validate-plan-network.py holds every declaration against the scripts
# the step's apply path actually runs; the declaration is data the installer
# reads, and the check is where being wrong about it is caught.
plan_add() {
  [[ $# -eq 7 ]] || die "plan_add requires id, label, phase, preflight, apply, note and scripts"
  local i existing

  # macOS still ships Bash 3.2. With nounset enabled, expanding an empty array
  # via "${array[@]}" raises an unbound-variable error there even when the
  # array was explicitly initialized. Track the count separately and only
  # index arrays that contain elements so the bootstrap path remains compatible
  # with the shell available before Homebrew is installed.
  for ((i=0; i<PLAN_COUNT; i++)); do
    existing="${PLAN_IDS[i]}"
    [[ "$existing" != "$1" ]] || die "Duplicate execution-plan step ID: $1"
  done
  PLAN_IDS+=("$1"); PLAN_LABELS+=("$2"); PLAN_PHASES+=("$3")
  PLAN_PREFLIGHTS+=("$4"); PLAN_APPLIES+=("$5")
  PLAN_NOTES+=("$6"); PLAN_SCRIPTS+=("$7")
  PLAN_COUNT=$((PLAN_COUNT + 1))
}

# plan_scripts: every repository script the resolved plan will run, one per
# line and without repetition. Only the steps that were actually added are
# walked, so an optional capability nobody selected contributes nothing.
plan_scripts() {
  local i script seen=""
  local -a declared
  for ((i=0; i<PLAN_COUNT; i++)); do
    [[ -n "${PLAN_SCRIPTS[i]}" ]] || continue
    read -ra declared <<<"${PLAN_SCRIPTS[i]}"
    for script in "${declared[@]}"; do
      case " $seen " in *" $script "*) continue ;; esac
      seen="${seen:+$seen }$script"
      printf '%s\n' "$script"
    done
  done
}

# A step whose work is one repository script states that command once, in a
# function printing its argument vector one argument per line, starting with
# the script's path relative to the checkout. The step's apply function runs
# the vector through plan_command_run and its note prints it through
# plan_command_note, so a dry-run can never describe a different script or
# different arguments than the ones apply runs.

# plan_command_note <command-function>: the vector as the plan shows it.
plan_command_note() {
  local argument note=""
  while IFS= read -r argument; do note+="${note:+ }$argument"; done < <("$1")
  printf '%s\n' "$note"
}

# plan_command_run <command-function> [argument]...: run the vector from this
# checkout. Extra arguments belong to this invocation only, not to the planned
# command, such as --non-interactive or --preflight.
plan_command_run() {
  local command_function="$1" argument
  local -a command=()
  shift
  while IFS= read -r argument; do command+=("$argument"); done < <("$command_function")
  ((${#command[@]} > 0)) || die "Plan command function printed no command: $command_function"
  "$DOTFILES_ROOT/${command[0]}" "${command[@]:1}" "$@"
}

plan_render() {
  local i
  printf 'Resolved steps (dry-run and apply use this exact order):\n'
  for ((i=0; i<PLAN_COUNT; i++)); do
    printf '  %2d. [%s] %s\n' "$((i + 1))" "${PLAN_IDS[i]}" "${PLAN_LABELS[i]}"
    [[ -z "${PLAN_NOTES[i]}" ]] || printf '      %s\n' "${PLAN_NOTES[i]}"
  done
}

# The contract for a preflight action, and the opposite of the one above: it
# runs where errexit reaches inside it, so the first refused prerequisite
# stops the run. A prerequisite is not an independent effect -- there is
# nothing for a preflight to report partially, and a check that has already
# said the run cannot proceed must not be followed by more checks against a
# machine it has ruled out.
#
# The positions that break that are the ones bash exempts from errexit, which
# it does for everything the exempted command runs, however deep: the
# condition of `if`, `while` or `until`, the operand of `!`, and every command
# in a `&&` or `||` list *except the last*. Written as `[[ ... ]] || "$action"`
# the action was the last command, which is why it propagated; written as
# `... || "$action" || warn ...` it would not. The body of an `if` is not a
# condition, so this shape keeps the action a plain statement and takes the
# question out of it.
#
# plan_preflight itself is subject to the same rule, and all four installers
# call it as a plain statement. Calling it any other way -- `plan_preflight ||
# status=$?` -- suppresses errexit through every check it runs.
plan_preflight() {
  local i action
  for ((i=0; i<PLAN_COUNT; i++)); do
    action="${PLAN_PREFLIGHTS[i]}"
    if [[ -n "$action" && "$action" != : ]]; then
      "$action"
    fi
  done
}

plan_pending_ids() {
  local start="${1:-0}" i result=""
  for ((i=start; i<PLAN_COUNT; i++)); do
    result="${result:+$result,}${PLAN_IDS[i]}"
  done
  printf '%s\n' "${result:-none}"
}

plan_completed_ids() {
  local result="" id i
  for ((i=0; i<PLAN_COMPLETED_COUNT; i++)); do
    id="${PLAN_COMPLETED[i]}"
    result="${result:+$result,}$id"
  done
  printf '%s\n' "${result:-none}"
}

plan_failure_report() {
  local index="$1" exit_code="$2"
  warn "Execution plan failed at [${PLAN_IDS[index]}] ${PLAN_LABELS[index]} (exit $exit_code)."
  warn "Completed steps: $(plan_completed_ids)"
  warn "Pending steps: $(plan_pending_ids "$((index + 1))")"
  warn "Installed state was not committed. Completed component changes are not rolled back."
  warn "Safe rerun: ${DOTFILES_RERUN_COMMAND:-./install.sh with the same options}"
  plan_log "failed id=${PLAN_IDS[index]} exit=$exit_code completed=$(plan_completed_ids) pending=$(plan_pending_ids "$((index + 1))")"
}

plan_execute() {
  local i action exit_code
  for ((i=0; i<PLAN_COUNT; i++)); do
    # Exposed to the lifecycle caller for failed-step state reporting.
    # shellcheck disable=SC2034
    PLAN_CURRENT_INDEX="$i"
    action="${PLAN_APPLIES[i]}"
    info "[${PLAN_IDS[i]}] ${PLAN_LABELS[i]}"
    plan_log "start id=${PLAN_IDS[i]} phase=${PLAN_PHASES[i]}"
    if [[ -n "$action" && "$action" != : ]]; then
      # The contract for a plan action: it runs with errexit suppressed, so it
      # must handle its own failures explicitly.
      #
      # Bash ignores errexit for an `if` condition and for everything that
      # condition runs, however deep — the same trap theme-hooks.sh documents
      # for its own boundary. The boundary there can be a subshell; this one
      # cannot, because an action such as macOS's activate_homebrew_path
      # mutates PATH for the steps that follow and has to run in this shell.
      # Every construct that captures a failure without aborting suppresses
      # errexit the same way, so the contract is explicit rather than
      # inherited: an action whose fallible command is not its last statement
      # must write `|| return` on that command, or the step reports as
      # completed after it failed.
      if "$action"; then
        exit_code=0
      else
        exit_code=$?
        plan_failure_report "$i" "$exit_code"
        return "$exit_code"
      fi
    fi
    PLAN_COMPLETED+=("${PLAN_IDS[i]}")
    PLAN_COMPLETED_COUNT=$((PLAN_COMPLETED_COUNT + 1))
    plan_log "success id=${PLAN_IDS[i]}"
    success "[${PLAN_IDS[i]}] completed"
  done
}
