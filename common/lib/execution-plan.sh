#!/usr/bin/env bash

# Lightweight ordered plan shared by dry-run, preflight, apply and verify.
# Callers register shell function names, keeping component scripts independently
# useful while eliminating a second hand-maintained dry-run orchestration.

PLAN_IDS=()
PLAN_LABELS=()
PLAN_PHASES=()
PLAN_PREFLIGHTS=()
PLAN_APPLIES=()
PLAN_VERIFIES=()
PLAN_NOTES=()
PLAN_COMPLETED=()
PLAN_CURRENT_INDEX=-1

plan_log() {
  [[ -n "${DOTFILES_PLAN_LOG:-}" ]] || return 0
  ensure_dir "$(dirname "$DOTFILES_PLAN_LOG")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$DOTFILES_PLAN_LOG"
  chmod 600 "$DOTFILES_PLAN_LOG"
}

plan_reset() {
  PLAN_IDS=(); PLAN_LABELS=(); PLAN_PHASES=(); PLAN_PREFLIGHTS=()
  PLAN_APPLIES=(); PLAN_VERIFIES=(); PLAN_NOTES=(); PLAN_COMPLETED=()
  PLAN_CURRENT_INDEX=-1
}

plan_add() {
  [[ $# -eq 7 ]] || die "plan_add requires id, label, phase, preflight, apply, verify and note"
  local existing
  for existing in "${PLAN_IDS[@]}"; do
    [[ "$existing" != "$1" ]] || die "Duplicate execution-plan step ID: $1"
  done
  PLAN_IDS+=("$1"); PLAN_LABELS+=("$2"); PLAN_PHASES+=("$3")
  PLAN_PREFLIGHTS+=("$4"); PLAN_APPLIES+=("$5"); PLAN_VERIFIES+=("$6")
  PLAN_NOTES+=("$7")
}

plan_render() {
  local i
  printf 'Resolved steps (dry-run and apply use this exact order):\n'
  for ((i=0; i<${#PLAN_IDS[@]}; i++)); do
    printf '  %2d. [%s] %s\n' "$((i + 1))" "${PLAN_IDS[i]}" "${PLAN_LABELS[i]}"
    [[ -z "${PLAN_NOTES[i]}" ]] || printf '      %s\n' "${PLAN_NOTES[i]}"
  done
}

plan_preflight() {
  local i action
  for ((i=0; i<${#PLAN_IDS[@]}; i++)); do
    action="${PLAN_PREFLIGHTS[i]}"
    [[ -z "$action" || "$action" == : ]] || "$action"
  done
}

plan_pending_ids() {
  local start="${1:-0}" i result=""
  for ((i=start; i<${#PLAN_IDS[@]}; i++)); do
    result="${result:+$result,}${PLAN_IDS[i]}"
  done
  printf '%s\n' "${result:-none}"
}

plan_completed_ids() {
  local result="" id
  for id in "${PLAN_COMPLETED[@]}"; do result="${result:+$result,}$id"; done
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
  for ((i=0; i<${#PLAN_IDS[@]}; i++)); do
    # Exposed to the lifecycle caller for failed-step state reporting.
    # shellcheck disable=SC2034
    PLAN_CURRENT_INDEX="$i"
    action="${PLAN_APPLIES[i]}"
    info "[${PLAN_IDS[i]}] ${PLAN_LABELS[i]}"
    plan_log "start id=${PLAN_IDS[i]} phase=${PLAN_PHASES[i]}"
    if [[ -n "$action" && "$action" != : ]]; then
      if "$action"; then
        exit_code=0
      else
        exit_code=$?
        plan_failure_report "$i" "$exit_code"
        return "$exit_code"
      fi
    fi
    PLAN_COMPLETED+=("${PLAN_IDS[i]}")
    plan_log "success id=${PLAN_IDS[i]}"
    success "[${PLAN_IDS[i]}] completed"
  done
}

plan_verify() {
  local i action
  for ((i=0; i<${#PLAN_IDS[@]}; i++)); do
    action="${PLAN_VERIFIES[i]}"
    [[ -z "$action" || "$action" == : ]] || "$action"
  done
}
