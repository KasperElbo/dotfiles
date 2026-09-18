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
log="$(mktemp)"; trap 'rm -f -- "$log" "$log.failure" "$log.first-failure"' EXIT
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
