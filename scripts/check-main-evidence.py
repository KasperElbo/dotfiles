#!/usr/bin/env python3
"""Report every main commit that has no finished, green Validate run of its own.

A pull request's run validates the PR merged into main as main stood when the
run started. Main can move after that, so the tree that lands is only proven by
the `push` run GitHub starts on the merge commit itself (#499). This asks
GitHub, for each commit on main's first-parent line, whether that run exists
and whether every job the commit's own `validate.yml` defines succeeded in it.

It also reads the rules GitHub applies to main and reports when merging does
not require those jobs, requires a check none of them provides, or does not
require the branch to be up to date with main first -- the setting that makes a pull request's run validate the tree
that will land, rather than a tree main has since moved past.

A commit is:

  green     a completed push run on main concluded `success` and each of the
            commit's validate.yml jobs concluded `success` in it;
  pending   a run for it is still queued or running, or it landed less than
            GRACE_MINUTES ago and GitHub has not created one yet;
  missing   anything else: no run, a cancelled run, a failed run, or a job the
            commit's workflow defines that the run did not report as passing.

The walk starts at main's tip and stops at the first commit whose tree does
not carry this script, so the check covers exactly the commits made since it
existed and needs no floor to maintain, and at MAX_COMMITS, and at commits
older than RETENTION_DAYS, whose runs GitHub no longer keeps.

A missing commit's run can be re-run from its Actions page, which re-validates
the same commit; a commit with no run at all cannot, and the report says so.

Exit status: 0 when nothing is missing and main's rules require the jobs,
1 otherwise, 2 on a usage or API error.

Usage:
    scripts/check-main-evidence.py --repository OWNER/NAME [--ref REF]
        [--report FILE] [--findings FILE] [--api-fixture FILE] [--now ISO-8601]

--findings writes only what is wrong -- the missing commits and the rule
problems, not the counts or the pending commits -- so it reads the same on
every run until something changes, which is what the workflow compares before
it comments on its tracking issue again.

GITHUB_TOKEN or GH_TOKEN authenticates the API calls when set. --api-fixture
reads every response from a JSON object keyed by request path instead of the
network, which is how tests/test-main-evidence.sh drives it.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
SELF = pathlib.Path("scripts/check-main-evidence.py")
WORKFLOW = ".github/workflows/validate.yml"
WORKFLOW_FILE = "validate.yml"
BRANCH = "main"
# A push run is created within seconds of the push. Half an hour covers an
# Actions outage short enough not to be worth an alert.
GRACE_MINUTES = 30
MAX_COMMITS = 100
# GitHub deletes workflow runs after the repository's retention period, 90 days
# by default; a commit older than that has lost its evidence either way.
RETENTION_DAYS = 90
# The runs and rules this reads are this repository's own, read-only.
# network-source: github-actions-api
API = "https://api.github.com"


def load_hygiene():
    """validate-repository-hygiene.py's workflow reader, which lint already trusts."""
    path = ROOT / "scripts" / "validate-repository-hygiene.py"
    spec = importlib.util.spec_from_file_location("repository_hygiene", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ApiError(Exception):
    pass


class Api:
    def __init__(self, fixture: pathlib.Path | None) -> None:
        self.responses = None
        if fixture is not None:
            self.responses = json.loads(fixture.read_text(encoding="utf-8"))
        self.token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    def get(self, path: str, **query: str) -> object:
        if query:
            path = f"{path}?{urllib.parse.urlencode(sorted(query.items()))}"
        if self.responses is not None:
            if path not in self.responses:
                raise ApiError(f"the fixture has no response for {path}")
            return self.responses[path]
        request = urllib.request.Request(f"{API}{path}")
        request.add_header("Accept", "application/vnd.github+json")
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise ApiError(f"GET {path} failed: {error}") from error


def git(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), *arguments], capture_output=True, text=True, check=False
    )


def first_parent_commits(ref: str, now: datetime.datetime) -> list[tuple[str, datetime.datetime]]:
    listed = git("rev-list", "--first-parent", f"--max-count={MAX_COMMITS}",
                 "--format=%ct", ref)
    if listed.returncode != 0:
        raise ApiError(f"git rev-list {ref} failed: {listed.stderr.strip()}")
    lines = [line for line in listed.stdout.splitlines() if line]
    commits = []
    oldest = now - datetime.timedelta(days=RETENTION_DAYS)
    for header, stamp in zip(lines[0::2], lines[1::2]):
        sha = header.removeprefix("commit ").strip()
        when = datetime.datetime.fromtimestamp(int(stamp), datetime.timezone.utc)
        if when < oldest:
            break
        if git("cat-file", "-e", f"{sha}:{SELF.as_posix()}").returncode != 0:
            break
        commits.append((sha, when))
    return commits


def required_jobs(hygiene, sha: str) -> list[str]:
    """The display names of the jobs the commit's own validate.yml defines."""
    shown = git("show", f"{sha}:{WORKFLOW}")
    if shown.returncode != 0:
        raise ApiError(f"{sha} has no {WORKFLOW}")
    workflow = hygiene.WorkflowReader(shown.stdout, f"{sha[:12]}:{WORKFLOW}").read()
    jobs = workflow.get("jobs")
    names = []
    for key, job in (jobs.items() if jobs is not None else []):
        name = job.get("name")
        names.append(name.value if name is not None and isinstance(name.value, str) else key)
    return names


def assess(api: Api, repository: str, sha: str, landed: datetime.datetime,
           now: datetime.datetime, jobs: list[str]) -> tuple[str, str]:
    runs = api.get(
        f"/repos/{repository}/actions/workflows/{WORKFLOW_FILE}/runs",
        head_sha=sha, event="push", branch=BRANCH, per_page="20",
    ).get("workflow_runs", [])
    runs = [run for run in runs if run.get("head_sha") == sha]
    if any(run.get("status") != "completed" for run in runs):
        running = next(run for run in runs if run.get("status") != "completed")
        return "pending", f"run {running.get('html_url')} is {running.get('status')}"
    problems = []
    for run in runs:
        url = run.get("html_url")
        if run.get("conclusion") != "success":
            problems.append(f"run {url} concluded `{run.get('conclusion')}`")
            continue
        listed = api.get(f"/repos/{repository}/actions/runs/{run['id']}/jobs",
                         filter="latest", per_page="100").get("jobs", [])
        outcome = {job.get("name"): job.get("conclusion") for job in listed}
        unmet = [f"`{name}` {outcome.get(name) or 'did not run'}"
                 for name in jobs if outcome.get(name) != "success"]
        if not unmet:
            return "green", f"run {url}"
        problems.append(f"run {url} succeeded without " + ", ".join(unmet))
    if problems:
        return "missing", "; ".join(problems) + ". Re-run it from its Actions page."
    if now - landed < datetime.timedelta(minutes=GRACE_MINUTES):
        return "pending", "no run yet, landed under half an hour ago"
    return "missing", ("GitHub started no Validate run for it, so it cannot be re-run; "
                       "its tree is proven only by a later commit's run")


def rule_problems(api: Api, repository: str, jobs: set[str]) -> list[str]:
    rules = api.get(f"/repos/{repository}/rules/branches/{BRANCH}")
    checks = [rule for rule in rules if rule.get("type") == "required_status_checks"]
    if not checks:
        return [f"merging into {BRANCH} requires no status check at all, so a pull "
                "request can merge with its Validate run red, running, or never started"]
    required = {
        check.get("context")
        for rule in checks
        for check in rule.get("parameters", {}).get("required_status_checks", [])
    }
    problems = []
    absent = sorted(jobs - required)
    if absent:
        problems.append(f"merging into {BRANCH} does not require "
                        + ", ".join(f"`{name}`" for name in absent))
    # The other direction (#538). A rule naming a context no job reports is
    # what a deleted or renamed job leaves behind: GitHub waits on it forever
    # or, once someone drops it to unblock a merge, the job is gone unnoticed.
    for context in sorted(required - jobs):
        problems.append(
            f"merging into {BRANCH} requires `{context}`, which no job in "
            f"{WORKFLOW_FILE} provides; it was renamed or deleted, and the rule "
            "now proves nothing"
        )
    if not any(rule.get("parameters", {}).get("strict_required_status_checks_policy")
               for rule in checks):
        problems.append(
            f"merging into {BRANCH} does not require the branch to be up to date "
            "first, so a pull request's green run can be for a tree main has "
            "since moved past"
        )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repository", required=True, help="OWNER/NAME")
    parser.add_argument("--ref", default=f"origin/{BRANCH}", help="main's tip (default: origin/main)")
    parser.add_argument("--report", type=pathlib.Path, help="also write the report to FILE")
    parser.add_argument("--findings", type=pathlib.Path, help="write only the findings to FILE")
    parser.add_argument("--api-fixture", type=pathlib.Path, help=argparse.SUPPRESS)
    parser.add_argument("--now", help=argparse.SUPPRESS)
    arguments = parser.parse_args()

    now = (datetime.datetime.fromisoformat(arguments.now) if arguments.now
           else datetime.datetime.now(datetime.timezone.utc))
    api = Api(arguments.api_fixture)
    hygiene = load_hygiene()
    try:
        commits = first_parent_commits(arguments.ref, now)
        if not commits:
            raise ApiError(f"{arguments.ref} does not carry {SELF.as_posix()}, so no "
                           "commit is in scope; check the ref")
        rows = []
        for sha, landed in commits:
            state, detail = assess(api, arguments.repository, sha, landed, now,
                                   required_jobs(hygiene, sha))
            rows.append((sha, state, detail))
        rules = rule_problems(api, arguments.repository,
                              set(required_jobs(hygiene, commits[0][0])))
    except (ApiError, hygiene.UnreadableWorkflow) as error:
        print(f"check-main-evidence: {error}", file=sys.stderr)
        return 2

    missing = [row for row in rows if row[1] == "missing"]
    findings = [f"- **missing** `{sha}`: {detail}" for sha, _, detail in missing]
    findings += [f"- {problem}." for problem in rules]
    if arguments.findings:
        arguments.findings.write_text("\n".join(findings) + ("\n" if findings else ""),
                                      encoding="utf-8")
    lines = ["## Main commit evidence", ""]
    lines.append(
        f"{len(rows)} commits on `{BRANCH}` since this check was added: "
        f"{sum(row[1] == 'green' for row in rows)} green, "
        f"{sum(row[1] == 'pending' for row in rows)} pending, {len(missing)} missing."
    )
    lines.append("")
    for sha, state, detail in rows:
        if state != "green":
            lines.append(f"- **{state}** `{sha}`: {detail}")
    if rules:
        lines += ["", "### Merge rules", ""]
        lines += [f"- {problem}." for problem in rules]
    report = "\n".join(lines) + "\n"
    print(report, end="")
    if arguments.report:
        arguments.report.write_text(report, encoding="utf-8")
    return 1 if missing or rules else 0


if __name__ == "__main__":
    raise SystemExit(main())
