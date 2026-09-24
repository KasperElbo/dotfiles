#!/usr/bin/env bash
# The report of main commits with no green Validate run of their own (#499).
#
# Every case runs the real script from a throwaway repository whose history it
# walks, and answers its API calls from a fixture, so nothing here reaches the
# network. A request the fixture does not answer is an error, so a commit the
# walk should have stopped before shows up as a failed run, not a silent pass.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root

repo="$TEST_ROOT/repo"
fixture="$TEST_ROOT/api.json"
now='2026-09-24T12:00:00+00:00'

git_in() {
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid "$@"
}

# commit_at <iso-date> <message>: one commit of whatever is staged, at a fixed
# time, so the grace window is decided by the fixture and not by the clock.
commit_at() {
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git_in commit -q --allow-empty -m "$2"
  git_in rev-parse HEAD
}

write_workflow() {
  mkdir -p "$repo/.github/workflows"
  {
    printf 'name: Validate\non:\n  pull_request:\njobs:\n'
    local job
    for job in "$@"; do
      printf '  %s:\n    name: %s job\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
        "$job" "$job"
    done
  } >"$repo/.github/workflows/validate.yml"
  git_in add .github/workflows/validate.yml
}

mkdir -p "$repo/scripts"
git -C "$repo" init -q -b main
# Before the check existed: the walk must stop here, and the fixture never
# answers for it, so reaching it is an error.
write_workflow alpha
before="$(commit_at '2026-09-20T10:00:00+00:00' 'before the check')"
cp "$repo_root/scripts/check-main-evidence.py" "$repo_root/scripts/validate-repository-hygiene.py" \
  "$repo/scripts/"
git_in add scripts
first="$(commit_at '2026-09-24T09:00:00+00:00' 'adds the check')"
write_workflow alpha beta
second="$(commit_at '2026-09-24T10:00:00+00:00' 'adds a job')"
third="$(commit_at '2026-09-24T11:50:00+00:00' 'lands ten minutes ago')"
[[ -n "$before" ]]

# fixture <rules> <sha>=<state>...: the API as this suite needs it.
#   state: green | cancelled | running | none | nobeta (a green run missing
#          the `beta` job)
#   rules: strict | loose | none | partial | orphan (also requires `gamma job`,
#          which no job provides) | keyed (also requires `beta`, the job's key
#          rather than the name its status is reported under)
fixture() {
  python3 - "$fixture" "$@" <<'PYTHON'
import json
import sys
import urllib.parse

path, rules, *commits = sys.argv[1:]
repository = "KasperElbo/dotfiles"
responses = {}
contexts = {
    "partial": ["alpha job"],
    "orphan": ["alpha job", "beta job", "gamma job"],
    "keyed": ["alpha job", "beta job", "beta"],
}.get(rules, ["alpha job", "beta job"])
if rules == "none":
    responses[f"/repos/{repository}/rules/branches/main"] = [{"type": "deletion"}]
else:
    responses[f"/repos/{repository}/rules/branches/main"] = [{
        "type": "required_status_checks",
        "parameters": {
            "strict_required_status_checks_policy": rules != "loose",
            "required_status_checks": [{"context": name} for name in contexts],
        },
    }]
for number, entry in enumerate(commits, 1):
    sha, state = entry.split("=")
    query = urllib.parse.urlencode(sorted(
        {"head_sha": sha, "event": "push", "branch": "main", "per_page": "20"}.items()))
    runs = []
    if state != "none":
        run = {
            "id": number, "head_sha": sha,
            "html_url": f"https://github.com/{repository}/actions/runs/{number}",
            "status": "in_progress" if state == "running" else "completed",
            "conclusion": {"cancelled": "cancelled", "running": None}.get(state, "success"),
        }
        runs.append(run)
        jobs = [{"name": "alpha job", "conclusion": "success"}]
        if state != "nobeta":
            jobs.append({"name": "beta job", "conclusion": "success"})
        responses[f"/repos/{repository}/actions/runs/{number}/jobs?"
                  + urllib.parse.urlencode(sorted({"filter": "latest", "per_page": "100"}.items()))] = {"jobs": jobs}
    responses[f"/repos/{repository}/actions/workflows/validate.yml/runs?{query}"] = {"workflow_runs": runs}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(responses, handle)
PYTHON
}

check() {
  run_capture python3 "$repo/scripts/check-main-evidence.py" --repository KasperElbo/dotfiles \
    --ref main --api-fixture "$fixture" --now "$now"
}

fixture strict "$third=green" "$second=green" "$first=green"
check
assert_success
assert_contains "$TEST_OUTPUT" '3 commits on `main` since this check was added: 3 green, 0 pending, 0 missing.'
printf 'PASS: every commit since the check was added, and none before it, is assessed\n'

# The shape #499 found on main: a run the next merge's run cancelled.
fixture strict "$third=green" "$second=cancelled" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**missing** \`$second\`: run https://github.com/KasperElbo/dotfiles/actions/runs/2 concluded \`cancelled\`. Re-run it from its Actions page."
printf 'PASS: a commit whose only run was cancelled is missing its evidence\n'

fixture strict "$third=green" "$second=none" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**missing** \`$second\`: GitHub started no Validate run for it, so it cannot be re-run"
printf 'PASS: a commit GitHub never ran is missing, and the report says a re-run cannot help\n'

# The newest commit landed ten minutes before `now`: no run yet is not a gap.
fixture strict "$third=none" "$second=green" "$first=green"
check
assert_success
assert_contains "$TEST_OUTPUT" "**pending** \`$third\`: no run yet, landed under half an hour ago"
printf 'PASS: a commit inside the grace window with no run yet is pending, not missing\n'

fixture strict "$third=running" "$second=green" "$first=green"
check
assert_success
assert_contains "$TEST_OUTPUT" "**pending** \`$third\`: run https://github.com/KasperElbo/dotfiles/actions/runs/1 is in_progress"
printf 'PASS: a commit whose run is still going is pending\n'

# Its workflow defines `beta`, so a green run that never reported it is not
# evidence; the first commit's workflow had no `beta`, so the same run is.
fixture strict "$third=green" "$second=nobeta" "$first=nobeta"
check
assert_failure
assert_contains "$TEST_OUTPUT" "**missing** \`$second\`: run https://github.com/KasperElbo/dotfiles/actions/runs/2 succeeded without \`beta job\` did not run"
assert_not_contains "$TEST_OUTPUT" "\`$first\`"
printf "PASS: the required jobs are the commit's own, not today's\n"

# The findings file is what the workflow compares before commenting again, so
# it carries the gaps and nothing that changes from one run to the next.
fixture strict "$third=none" "$second=cancelled" "$first=green"
run_capture python3 "$repo/scripts/check-main-evidence.py" --repository KasperElbo/dotfiles \
  --ref main --api-fixture "$fixture" --now "$now" --findings "$TEST_ROOT/findings.md"
assert_failure
assert_eq "- **missing** \`$second\`: run https://github.com/KasperElbo/dotfiles/actions/runs/2 concluded \`cancelled\`. Re-run it from its Actions page." \
  "$(cat "$TEST_ROOT/findings.md")"
printf 'PASS: the findings name the gap and leave out counts and pending commits\n'

fixture strict "$third=green" "$second=green" "$first=green"
run_capture python3 "$repo/scripts/check-main-evidence.py" --repository KasperElbo/dotfiles \
  --ref main --api-fixture "$fixture" --now "$now" --findings "$TEST_ROOT/findings.md"
assert_success
assert_file_empty "$TEST_ROOT/findings.md"
printf 'PASS: a clean main writes an empty findings file, which closes the issue\n'

# --- Main's merge rules -----------------------------------------------------

fixture none "$third=green" "$second=green" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" 'merging into main requires no status check at all'
printf 'PASS: a main that requires no check is reported\n'

fixture partial "$third=green" "$second=green" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" 'merging into main does not require `beta job`'
printf 'PASS: a job the rules leave out is named\n'

fixture loose "$third=green" "$second=green" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" 'does not require the branch to be up to date first'
printf 'PASS: rules that do not require an up-to-date branch are reported\n'

# The other direction (#538): a context the rules require that no job in the
# tip's validate.yml provides. It is what a deleted or renamed job leaves
# behind, and it made "every job is required" read the same as "one required
# check proves nothing".
fixture orphan "$third=green" "$second=green" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" 'merging into main requires `gamma job`, which no job in validate.yml provides; it was renamed or deleted, and the rule now proves nothing'
assert_not_contains "$TEST_OUTPUT" '`alpha job`, which'
printf 'PASS: a required context no job provides is named\n'

# GitHub reports a job under its name, so a rule naming the job's key waits on
# a context that never arrives, though the key is right there in the workflow.
fixture keyed "$third=green" "$second=green" "$first=green"
check
assert_failure
assert_contains "$TEST_OUTPUT" 'merging into main requires `beta`, which no job in validate.yml provides'
printf "PASS: a rule naming a job's key rather than its name is reported\n"

# --- Refusals ---------------------------------------------------------------

check_ref() {
  run_capture python3 "$repo/scripts/check-main-evidence.py" --repository KasperElbo/dotfiles \
    --ref "$1" --api-fixture "$fixture" --now "$now"
}
fixture strict "$third=green" "$second=green" "$first=green"
check_ref "$before"
assert_status 2
assert_contains "$TEST_OUTPUT" 'does not carry scripts/check-main-evidence.py, so no commit is in scope'
printf 'PASS: a ref from before the check is refused rather than reported clean\n'

# A fixture that does not answer for a commit in scope is an error, not a pass.
fixture strict "$third=green" "$second=green"
check
assert_status 2
assert_contains "$TEST_OUTPUT" 'the fixture has no response for'
printf 'PASS: an unanswered request fails the run\n'

printf '\nAll main-evidence checks passed.\n'
