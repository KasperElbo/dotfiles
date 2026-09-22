#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$repo_root" bash -c '
  set +e +u
  set +o pipefail
  before="$(set +o)"
  source "$REPO_ROOT/common/lib/common.sh"
  source "$REPO_ROOT/common/lib/execution-plan.sh"
  after="$(set +o)"
  [[ "$before" == "$after" ]]
'
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/execution-plan.sh
source "$repo_root/common/lib/execution-plan.sh"
log="$(mktemp)"; trap 'rm -f -- "$log" "$log.failure" "$log.first-failure" "$log.two-statement" "$log.preflight"' EXIT
one() { printf 'one\n' >>"$log"; }
two() { printf 'two\n' >>"$log"; }
plan_add one 'First step' apply : one : rerunnable ''
plan_add two 'Second step' apply : two : rerunnable ''
rendered="$(plan_render)"
plan_execute >/dev/null
[[ "$(paste -sd, "$log")" == one,two ]]
[[ "$rendered" == *'[one] First step'* && "$rendered" == *'[two] Second step'* ]]
printf 'Shared execution plan ordering passed.\n'

fail_step() { return 23; }
plan_reset
plan_add first-broken 'First injected failure' apply : fail_step : rerunnable ''
plan_add first-pending 'Still pending' apply : two : rerunnable ''
if plan_execute >"$log.first-failure" 2>&1; then
  printf 'First-step execution-plan failure unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'Completed steps: none' "$log.first-failure"
grep -Fq 'Pending steps: first-pending' "$log.first-failure"
printf 'Execution-plan empty-completed diagnostics passed.\n'

plan_reset
plan_add 'done' 'Completed step' apply : one : rerunnable ''
plan_add broken 'Injected failure' apply : fail_step : rerunnable ''
plan_add pending 'Pending step' apply : two : rerunnable ''
if plan_execute >"$log.failure" 2>&1; then
  printf 'Injected execution-plan failure unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'failed at [broken] Injected failure' "$log.failure"
grep -Fq 'Completed steps: done' "$log.failure"
grep -Fq 'Pending steps: pending' "$log.failure"
printf 'Execution-plan failure diagnostics passed.\n'

# A plan action runs with errexit suppressed, because plan_execute uses it as
# an `if` condition. An action that runs anything after its fallible command
# must therefore propagate that command's failure itself. This case is the
# shape of platforms/macos/lib/install-actions.sh's macos_run_system_installer:
# a failing installer followed by an always-succeeding PATH export.
plan_reset
after_failure_ran=false
always_succeeds() { after_failure_ran=true; }
guarded_two_statement_step() {
  fail_step || return
  always_succeeds
}
plan_add guarded 'Two-statement action guarding its fallible command' \
  apply : guarded_two_statement_step : rerunnable ''
plan_add unreached 'Must not run after the failure' apply : two : rerunnable ''
if plan_execute >"$log.two-statement" 2>&1; then
  printf 'A failing two-statement action was reported as successful.\n' >&2
  exit 1
fi
grep -Fq 'failed at [guarded] Two-statement action guarding its fallible command' \
  "$log.two-statement"
grep -Fq 'Completed steps: none' "$log.two-statement"
grep -Fq 'Pending steps: unreached' "$log.two-statement"
[[ "$after_failure_ran" == false ]] ||
  { printf 'Execution continued past the failed command inside the action.\n' >&2; exit 1; }
printf 'Execution-plan two-statement action failure passed.\n'

# The negative control: the same shape without the guard is exactly the defect,
# so it must still be reported as successful here. This is not an endorsement
# of the shape; it is the proof that the guard above is what does the work, so
# a future refactor that makes the boundary itself propagate will fail this
# assertion and force the contract comment to be rewritten with it.
plan_reset
unguarded_two_statement_step() {
  fail_step
  always_succeeds
}
plan_add unguarded 'Two-statement action without the guard' \
  apply : unguarded_two_statement_step : rerunnable ''
plan_execute >/dev/null 2>&1 ||
  { printf 'The unguarded shape now propagates; update the contract comment in common/lib/execution-plan.sh.\n' >&2; exit 1; }
printf 'Execution-plan errexit-suppression contract confirmed.\n'

# --- The preflight boundary is the opposite contract (#368) -----------------
#
# A preflight action is a prerequisite, not an independent effect: the first
# check that says the run cannot proceed must stop it, and the checks after it
# must not run against a machine it has already ruled out. plan_preflight runs
# each action as a plain statement so errexit reaches inside it.
#
# Both cases run in their own `bash`, not in this shell. The status of a
# statement that errexit aborts cannot be captured with `if`, `||` or a
# subshell here: every one of those is a context in which bash suppresses
# errexit for everything the statement runs, however deep, which is the same
# trap common/lib/theme-hooks.sh documents for its own boundary -- and, run
# that way, a harness reports a propagating plan_preflight as though it had
# swallowed the failure.
preflight_probe() {
  local shape="$1"
  PROBE_REPO="$repo_root" PROBE_SENTINEL="$log.preflight" PROBE_SHAPE="$shape" \
    bash -c '
      set -euo pipefail
      source "$PROBE_REPO/common/lib/common.sh"
      source "$PROBE_REPO/common/lib/execution-plan.sh"
      : >"$PROBE_SENTINEL"
      refuses() { printf "first-check\n" >>"$PROBE_SENTINEL"; return 23; }
      two_check_preflight() {
        refuses
        printf "second-check\n" >>"$PROBE_SENTINEL"
      }
      later_preflight() { printf "later-step\n" >>"$PROBE_SENTINEL"; }
      plan_add refused "Refused prerequisite" apply two_check_preflight : : note ""
      plan_add later "A later step" apply later_preflight : : note ""
      if [[ "$PROBE_SHAPE" == suppressed ]]; then
        # The negative control: the same loop with the action moved into a
        # context bash suppresses errexit in. Nothing calls plan_preflight this
        # way; it is here so the assertions above fail if the real boundary
        # ever grows this shape.
        plan_preflight() {
          local i action
          for ((i = 0; i < PLAN_COUNT; i++)); do
            action="${PLAN_PREFLIGHTS[i]}"
            if [[ -n "$action" && "$action" != : ]]; then
              "$action" || true
            fi
          done
        }
      fi
      plan_preflight
      printf "returned-from-plan-preflight\n" >>"$PROBE_SENTINEL"
    ' 2>/dev/null
}

if preflight_probe propagating; then
  printf 'A refused prerequisite let plan_preflight return successfully.\n' >&2
  exit 1
fi
preflight_probe propagating || probe_status=$?
((probe_status == 23)) ||
  { printf 'plan_preflight lost the prerequisite exit status: %s, not 23.\n' \
    "$probe_status" >&2; exit 1; }
[[ "$(paste -sd, "$log.preflight")" == first-check ]] ||
  { printf 'plan_preflight ran past the refused prerequisite: %s\n' \
    "$(paste -sd, "$log.preflight")" >&2; exit 1; }
printf 'Execution-plan preflight stops at the first refused prerequisite\n'

# The negative control, and what makes the two assertions above load-bearing:
# the identical plan with the action in a suppressed context reaches the second
# check, the later step and the end, and reports success.
preflight_probe suppressed ||
  { printf 'The suppressed control now propagates; the assertions above prove nothing.\n' >&2
    exit 1; }
[[ "$(paste -sd, "$log.preflight")" == \
  first-check,second-check,later-step,returned-from-plan-preflight ]] ||
  { printf 'The suppressed control did not run on: %s\n' \
    "$(paste -sd, "$log.preflight")" >&2; exit 1; }
printf 'Execution-plan preflight propagation control confirmed\n'
