#!/usr/bin/env bash
# The report of self-hosted real-install jobs with no recent success (#501).
#
# Every case runs the real script from a throwaway repository and answers its
# API calls from a fixture, so nothing here reaches the network. A request the
# fixture does not answer is an error, which is how a run the script should
# have skipped without asking about shows up as a failure.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root

repo="$TEST_ROOT/repo"
fixture="$TEST_ROOT/api.json"
now='2026-09-24T12:00:00+00:00'
wsl='WSL job (self-hosted)'
parrot='Parrot job (self-hosted)'

git_in() {
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"
}

# write_workflow <self-hosted job>...: a real-install.yml with one hosted job
# and the named jobs on self-hosted runners.
write_workflow() {
  mkdir -p "$repo/.github/workflows"
  {
    printf 'name: Real install\non:\n  workflow_dispatch:\njobs:\n'
    printf '  hosted:\n    name: Hosted job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    local job
    for job in "$@"; do
      printf '  %s:\n    name: %s\n    runs-on: [self-hosted, Linux]\n    steps:\n      - run: "true"\n' \
        "$job" "$(if [[ "$job" == wsl ]]; then printf '%s' "$wsl"; else printf '%s' "$parrot"; fi)"
    done
  } >"$repo/.github/workflows/real-install.yml"
  git_in add .github/workflows/real-install.yml
}

mkdir -p "$repo/scripts"
git -C "$repo" init -q -b main
cp "$repo_root/scripts/check-self-hosted-evidence.py" "$repo_root/scripts/check-main-evidence.py" \
  "$repo_root/scripts/validate-repository-hygiene.py" "$repo/scripts/"
git_in add scripts
write_workflow wsl parrot
git_in commit -q -m 'old'
old="$(git_in rev-parse HEAD)"
git_in commit -q --allow-empty -m 'new'
new="$(git_in rev-parse HEAD)"
git_in checkout -q -b side
git_in commit -q --allow-empty -m 'not on main'
side="$(git_in rev-parse HEAD)"
git_in checkout -q main

# fixture <run>...: dispatched runs of real-install.yml, newest or not in any
# order, each `<id>,<sha>,<date>,<job>=<conclusion>[,<job>=<conclusion>...]`
# with jobs named wsl, parrot or hosted. A run whose id starts with `x` gets no
# jobs response, so asking for its jobs fails the run.
fixture() {
  python3 - "$fixture" "$@" <<'PYTHON'
import json
import sys
import urllib.parse

path, *specs = sys.argv[1:]
repository = "KasperElbo/dotfiles"
names = {"wsl": "WSL job (self-hosted)", "parrot": "Parrot job (self-hosted)",
         "hosted": "Hosted job"}
responses = {}
runs = []
for spec in specs:
    number, sha, date, *jobs = spec.split(",")
    runs.append({"id": number, "head_sha": sha, "created_at": f"{date}T08:00:00Z",
                 "html_url": f"https://github.com/{repository}/actions/runs/{number}"})
    if number.startswith("x"):
        continue
    listed = []
    for job in jobs:
        key, conclusion = job.split("=")
        listed.append({"name": names[key], "conclusion": conclusion,
                       "completed_at": f"{date}T09:00:00Z",
                       "html_url": f"https://github.com/{repository}/actions/runs/{number}/job/{key}"})
    query = urllib.parse.urlencode(sorted({"filter": "latest", "per_page": "100"}.items()))
    responses[f"/repos/{repository}/actions/runs/{number}/jobs?{query}"] = {"jobs": listed}
query = urllib.parse.urlencode(sorted(
    {"event": "workflow_dispatch", "status": "completed", "per_page": "100"}.items()))
responses[f"/repos/{repository}/actions/workflows/real-install.yml/runs?{query}"] = {
    "workflow_runs": runs}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(responses, handle)
PYTHON
}

check() {
  run_capture python3 "$repo/scripts/check-self-hosted-evidence.py" --repository KasperElbo/dotfiles \
    --ref main --api-fixture "$fixture" --now "${1:-$now}" --findings "$TEST_ROOT/findings.md"
}

fixture "1,$new,2026-09-21,wsl=success,parrot=success,hosted=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-21 on \`$new\` (0 commits behind \`main\`), https://github.com/KasperElbo/dotfiles/actions/runs/1/job/wsl"
assert_contains "$TEST_OUTPUT" "**current** \`$parrot\`: succeeded 2026-09-21"
assert_not_contains "$TEST_OUTPUT" 'Hosted job'
assert_file_empty "$TEST_ROOT/findings.md"
printf 'PASS: self-hosted jobs that succeeded this month are current, and hosted jobs are not checked\n'

# A newer run that failed does not hide the older success, and each job's own
# newest success is found, whichever run carries it.
fixture "2,$new,2026-09-22,wsl=failure,parrot=skipped" "1,$old,2026-09-10,wsl=success,parrot=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-10 on \`$old\` (1 commits behind \`main\`)"
printf 'PASS: a newer failed run falls back to the newest success\n'

# The API's order is not relied on: the newest success wins wherever it is listed.
fixture "1,$old,2026-08-01,wsl=success,parrot=success" "2,$new,2026-09-22,wsl=success,parrot=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$parrot\`: succeeded 2026-09-22 on \`$new\`"
printf 'PASS: the newest success is found whatever order the runs are listed in\n'

fixture "2,$new,2026-09-22,wsl=success,parrot=skipped" "1,$old,2026-08-01,wsl=success,parrot=success"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`"
assert_contains "$TEST_OUTPUT" "**stale** \`$parrot\`: succeeded 2026-08-01 on \`$old\`"
assert_eq "- \`$parrot\` last succeeded 2026-08-01 on \`$old\` (https://github.com/KasperElbo/dotfiles/actions/runs/1/job/parrot), more than 30 days ago. Dispatch real-install.yml on main with its input set." \
  "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: a job whose newest success is over a month old is stale\n'

# The findings are compared before the tracking issue is commented on again,
# so a week of the same stale job must read the same every day.
first_findings="$(cat "$TEST_ROOT/findings.md")"
check '2026-10-01T12:00:00+00:00'
assert_failure
assert_eq "$first_findings" "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: the findings do not change from day to day while nothing succeeds\n'

fixture "1,$new,2026-09-22,wsl=success,parrot=skipped"
check
assert_failure
assert_contains "$(cat "$TEST_ROOT/findings.md")" "\`$parrot\` has no successful run on a commit main contains"
assert_not_contains "$(cat "$TEST_ROOT/findings.md")" "$wsl"
printf 'PASS: a job that never succeeded is stale\n'

# A success on a branch main does not contain is not evidence for main. The
# run has no jobs response, so even asking about it fails the check.
fixture "x9,$side,2026-09-23,wsl=success,parrot=success" "1,$new,2026-09-22,wsl=success,parrot=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-22 on \`$new\`"
printf 'PASS: a run on a commit main does not contain is skipped\n'

# --- Refusals ---------------------------------------------------------------

write_workflow
git_in commit -q -m 'no self-hosted jobs'
fixture "1,$new,2026-09-22,wsl=success,parrot=success"
check
assert_status 2
assert_contains "$TEST_OUTPUT" 'has no self-hosted job, so there is nothing to check'
printf 'PASS: a workflow with no self-hosted job is refused rather than reported clean\n'

printf '\nAll self-hosted evidence checks passed.\n'
