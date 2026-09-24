#!/usr/bin/env bash
# The report of real-install jobs with no recent success (#501, #538).
#
# Every case runs the real script from a throwaway repository carrying the real
# real-install.yml, and answers its API calls from a fixture, so nothing here
# reaches the network. A request the fixture does not answer is an error, which
# is how a run the script should have skipped without asking about shows up as
# a failure. Carrying the real workflow also holds the script's table of jobs
# to the jobs that workflow defines: one added, renamed or deleted without the
# table following fails the first case.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root

repo="$TEST_ROOT/repo"
fixture="$TEST_ROOT/api.json"
workflow="$repo/.github/workflows/real-install.yml"
now='2026-09-24T12:00:00+00:00'

git_in() {
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"
}

# job_name <key>: the name the real workflow gives that job, which is what the
# jobs API reports and so what the report names.
job_name() {
  python3 - "$repo_root" "$1" <<'PYTHON'
import importlib.util
import pathlib
import sys

root, key = pathlib.Path(sys.argv[1]), sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "hygiene", root / "scripts" / "validate-repository-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)
workflow = hygiene.read_workflow(root / ".github/workflows/real-install.yml", "real-install.yml")
job = workflow.get("jobs").get(key)
if job is None:
    raise SystemExit(f"real-install.yml has no job {key!r}")
print(job.get("name").value)
PYTHON
}

fedora="$(job_name fedora)"
wsl="$(job_name fedora-wsl-real)"
parrot="$(job_name parrot-real-vm)"

# edit_workflow <old> <new>: one exact replacement in the fixture's
# real-install.yml, committed, refusing if <old> is not there.
edit_workflow() {
  python3 - "$workflow" "$1" "$2" <<'PYTHON'
import pathlib
import sys

workflow, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = workflow.read_text(encoding="utf-8")
if old not in text:
    raise SystemExit(f"the fixture workflow has no {old!r} to replace")
workflow.write_text(text.replace(old, new, 1), encoding="utf-8")
PYTHON
  git_in commit -q -am 'edits the workflow'
}

mkdir -p "$repo/scripts" "$repo/.github/workflows"
git -C "$repo" init -q -b main
cp "$repo_root/scripts/check-real-install-evidence.py" "$repo_root/scripts/check-main-evidence.py" \
  "$repo_root/scripts/validate-repository-hygiene.py" "$repo/scripts/"
cp "$repo_root/.github/workflows/real-install.yml" "$workflow"
git_in add scripts .github
git_in commit -q -m 'old'
old="$(git_in rev-parse HEAD)"
git_in commit -q --allow-empty -m 'new'
new="$(git_in rev-parse HEAD)"
git_in checkout -q -b side
git_in commit -q --allow-empty -m 'not on main'
side="$(git_in rev-parse HEAD)"
git_in checkout -q main

# fixture <run>...: completed runs of real-install.yml, in any order, each
# `<id>,<sha>,<date>,<event>,<job>=<conclusion>[,<job>=<conclusion>...]` with
# <event> schedule or dispatch and each <job> a key of the real workflow. A run
# whose id starts with `x` gets no jobs response, so asking for its jobs fails
# the run.
fixture() {
  python3 - "$repo_root" "$fixture" "$@" <<'PYTHON'
import importlib.util
import json
import pathlib
import sys
import urllib.parse

root, path, *specs = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "hygiene", pathlib.Path(root) / "scripts" / "validate-repository-hygiene.py")
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)
workflow = hygiene.read_workflow(
    pathlib.Path(root) / ".github/workflows/real-install.yml", "real-install.yml")
names = {key: job.get("name").value for key, job in workflow.get("jobs").items()}
repository = "KasperElbo/dotfiles"
responses = {}
runs = {"schedule": [], "workflow_dispatch": []}
for entry in specs:
    number, sha, date, event, *jobs = entry.split(",")
    event = {"schedule": "schedule", "dispatch": "workflow_dispatch"}[event]
    runs[event].append({
        "id": number, "head_sha": sha, "created_at": f"{date}T08:00:00Z",
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
for event, listed in runs.items():
    query = urllib.parse.urlencode(sorted(
        {"event": event, "status": "completed", "per_page": "100"}.items()))
    responses[f"/repos/{repository}/actions/workflows/real-install.yml/runs?{query}"] = {
        "workflow_runs": listed}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(responses, handle)
PYTHON
}

check() {
  run_capture python3 "$repo/scripts/check-real-install-evidence.py" --repository KasperElbo/dotfiles \
    --ref main --api-fixture "$fixture" --now "${1:-$now}" --findings "$TEST_ROOT/findings.md"
}

# A Sunday that went green for the four hosted jobs, and a dispatch this month
# that went green for all six.
hosted='fedora=success,macos=success,windows-boundary=success,parrot-image-boundary=success'
sunday="1,$new,2026-09-20,schedule,$hosted,fedora-wsl-real=skipped,parrot-real-vm=skipped"
dispatched="2,$old,2026-09-10,dispatch,$hosted,fedora-wsl-real=success,parrot-real-vm=success"

fixture "$sunday" "$dispatched"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$fedora\`: succeeded 2026-09-20 on \`$new\` (0 commits behind \`main\`), https://github.com/KasperElbo/dotfiles/actions/runs/1/job/fedora"
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-10 on \`$old\` (1 commits behind \`main\`), https://github.com/KasperElbo/dotfiles/actions/runs/2/job/fedora-wsl-real"
assert_contains "$TEST_OUTPUT" "**current** \`$parrot\`: succeeded 2026-09-10"
assert_eq 6 "$(grep -c '^- \*\*current\*\*' <<<"$TEST_OUTPUT")" 'every real-install job is reported'
assert_file_empty "$TEST_ROOT/findings.md"
printf 'PASS: every job in real-install.yml, hosted and self-hosted, is reported current\n'

# The obvious gap (#538): a hosted job whose schedule stopped going green.
fixture "1,$new,2026-09-20,schedule,fedora=failure,macos=success,windows-boundary=success,parrot-image-boundary=success" \
  "2,$old,2026-09-04,dispatch,$hosted,fedora-wsl-real=success,parrot-real-vm=success"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**stale** \`$fedora\`: succeeded 2026-09-04 on \`$old\`"
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`"
assert_eq "- \`$fedora\` last succeeded 2026-09-04 on \`$old\` (https://github.com/KasperElbo/dotfiles/actions/runs/2/job/fedora), more than 10 days ago. Its Sunday schedule has not produced a green run since; find out why in real-install.yml's recent runs, or dispatch it on main." \
  "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: a hosted job whose newest success is 20 days old is stale\n'

# The subtler one: one missed Sunday is allowed, a second is not. The Monday
# after the missed Sunday is current, and so is the last second of ten days.
fixture "1,$new,2026-09-13,schedule,$hosted" "$dispatched"
check '2026-09-21T07:17:00+00:00'
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$fedora\`: succeeded 2026-09-13"
check '2026-09-23T09:00:00+00:00'
assert_success
check '2026-09-23T09:00:01+00:00'
assert_failure
assert_contains "$TEST_OUTPUT" "**stale** \`$fedora\`: succeeded 2026-09-13"
check '2026-09-28T07:17:00+00:00'
assert_failure
printf 'PASS: a hosted job is stale once a second Sunday passes without a success\n'

# A hosted job's newest success came only from its schedule, which a search
# of dispatched runs alone never sees.
fixture "1,$new,2026-09-20,schedule,$hosted" \
  "2,$old,2026-09-10,dispatch,fedora-wsl-real=success,parrot-real-vm=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$fedora\`: succeeded 2026-09-20 on \`$new\`"
printf 'PASS: scheduled runs count as evidence, not only dispatched ones\n'

# A newer run that failed does not hide the older success, and each job's own
# newest success is found, whichever run carries it.
fixture "3,$new,2026-09-22,dispatch,fedora-wsl-real=failure,parrot-real-vm=skipped" "$sunday" "$dispatched"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-10 on \`$old\` (1 commits behind \`main\`)"
printf 'PASS: a newer failed run falls back to the newest success\n'

# The API's order is not relied on: the newest success wins wherever it is listed.
fixture "$dispatched" "$sunday" "3,$new,2026-09-22,dispatch,fedora-wsl-real=success,parrot-real-vm=success"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$parrot\`: succeeded 2026-09-22 on \`$new\`"
printf 'PASS: the newest success is found whatever order the runs are listed in\n'

fixture "$sunday" "3,$new,2026-09-22,dispatch,fedora-wsl-real=success,parrot-real-vm=skipped" \
  "2,$old,2026-08-01,dispatch,fedora-wsl-real=success,parrot-real-vm=success"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`"
assert_contains "$TEST_OUTPUT" "**stale** \`$parrot\`: succeeded 2026-08-01 on \`$old\`"
assert_eq "- \`$parrot\` last succeeded 2026-08-01 on \`$old\` (https://github.com/KasperElbo/dotfiles/actions/runs/2/job/parrot-real-vm), more than 30 days ago. Dispatch real-install.yml on main with its input set." \
  "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: a self-hosted job whose newest success is over a month old is stale\n'

# The findings are compared before the tracking issue is commented on again,
# so days of the same stale job must read the same every day.
first_findings="$(cat "$TEST_ROOT/findings.md")"
check '2026-09-29T12:00:00+00:00'
assert_failure
assert_eq "$first_findings" "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: the findings do not change from day to day while nothing succeeds\n'

fixture "$sunday" "3,$new,2026-09-22,dispatch,fedora-wsl-real=success,parrot-real-vm=skipped"
check
assert_failure
assert_contains "$(cat "$TEST_ROOT/findings.md")" "\`$parrot\` has no successful run on a commit main contains"
assert_not_contains "$(cat "$TEST_ROOT/findings.md")" "$wsl"
printf 'PASS: a job that never succeeded is stale\n'

# A success on a branch main does not contain is not evidence for main. The
# run has no jobs response, so even asking about it fails the check.
fixture "x9,$side,2026-09-23,dispatch,fedora-wsl-real=success,parrot-real-vm=success" "$sunday" "$dispatched"
check
assert_success
assert_contains "$TEST_OUTPUT" "**current** \`$wsl\`: succeeded 2026-09-10 on \`$old\`"
printf 'PASS: a run on a commit main does not contain is skipped\n'

# Which jobs are watched is the table, not a runner label: a self-hosted job
# that lost `self-hosted` from its runs-on is still reported (#538).
edit_workflow '    runs-on: [self-hosted, Windows, X64, dotfiles-wsl]' \
  '    runs-on: [Windows, X64, dotfiles-wsl]'
fixture "$sunday" "3,$new,2026-09-22,dispatch,parrot-real-vm=success"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**stale** \`$wsl\`"
assert_contains "$(cat "$TEST_ROOT/findings.md")" "\`$wsl\` has no successful run on a commit main contains"
git_in reset -q --hard HEAD~1
printf 'PASS: a self-hosted job that lost its label is still watched\n'

# --- Refusals ---------------------------------------------------------------

# A job the table gives no age would go unwatched, and a table entry with no
# job watches nothing; either is refused rather than reported clean.
edit_workflow $'jobs:\n' $'jobs:\n  extra:\n    name: Extra job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n\n'
fixture "$sunday" "$dispatched"
check
assert_status 2
assert_contains "$TEST_OUTPUT" 'real-install.yml defines job `extra`, which MAX_AGE_DAYS gives no age'
git_in reset -q --hard HEAD~1
printf 'PASS: a job the table does not cover is refused\n'

edit_workflow '  parrot-real-vm:' '  parrot-vm:'
fixture "$sunday" "$dispatched"
check
assert_status 2
assert_contains "$TEST_OUTPUT" 'real-install.yml has no job `parrot-real-vm`, which MAX_AGE_DAYS watches'
git_in reset -q --hard HEAD~1
printf 'PASS: a table entry for a job that was renamed is refused\n'

printf '\nAll real-install evidence checks passed.\n'
