#!/usr/bin/env python3
"""Report the real-install jobs that have not succeeded recently.

real-install.yml is the only place anything is actually installed, and none of
it gates a merge. Its four hosted jobs run on the Sunday schedule; the Fedora
WSL and Parrot VM jobs run on Kasper's own machines, only when someone
dispatches them (#501). docs/testing.md rests the cost of that cadence on
those runs happening, so a schedule that stops going green, or a self-hosted
job nobody dispatches, has to be noticed rather than assumed away (#538).

For every job in MAX_AGE_DAYS, this finds the newest scheduled or dispatched
run in which that job concluded `success` on a commit main contains, and
reports its date, its commit and how many commits main has gained since. A
job is:

  current   it succeeded within its MAX_AGE_DAYS;
  stale     its newest success is older than that, or it has none GitHub still
            keeps a record of.

The table has to name exactly the jobs the workflow on --ref defines: a job it
does not cover would go unwatched, and an entry with no job watches nothing, so
either is refused. Which jobs are watched is therefore never read off a runner
label. Runs on a branch main does not contain are not evidence for main and are
skipped.

Exit status: 0 when every job is current, 1 otherwise, 2 on a usage, API or
table error.

Usage:
    scripts/check-real-install-evidence.py --repository OWNER/NAME [--ref REF]
        [--report FILE] [--findings FILE] [--api-fixture FILE] [--now ISO-8601]

--findings writes only the stale jobs, in words that do not change until one
of them succeeds again, which is what the workflow compares before it comments
on its tracking issue again. GITHUB_TOKEN or GH_TOKEN authenticates the API
calls; --api-fixture answers them from a file, as in check-main-evidence.py.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ".github/workflows/real-install.yml"
WORKFLOW_FILE = "real-install.yml"
BRANCH = "main"
# The events whose runs count. The schedule runs the hosted jobs; a dispatch
# runs any of them, and is the only way the self-hosted ones run at all.
EVENTS = ("schedule", "workflow_dispatch")
SCHEDULED = (
    "Its Sunday schedule has not produced a green run since; find out why in "
    "real-install.yml's recent runs, or dispatch it on main."
)
DISPATCHED = "Dispatch real-install.yml on main with its input set."
# How old each job's newest success may be, by job key, and what clears it.
MAX_AGE_DAYS = {
    # Weekly on Sunday: ten days allows one missed Sunday and reports the
    # second, rather than the fourth.
    "fedora": (10, SCHEDULED),
    "macos": (10, SCHEDULED),
    "windows-boundary": (10, SCHEDULED),
    "parrot-image-boundary": (10, SCHEDULED),
    # Once a month: often enough that a regression on these machines is found
    # within a few weeks of the change that caused it.
    "fedora-wsl-real": (30, DISPATCHED),
    "parrot-real-vm": (30, DISPATCHED),
}


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evidence = load("main_evidence", "check-main-evidence.py")
git = evidence.git
ApiError = evidence.ApiError


def watched_jobs(hygiene, ref: str) -> dict[str, str]:
    """Each job key in MAX_AGE_DAYS and the name the workflow on REF gives it."""
    shown = git("show", f"{ref}:{WORKFLOW}")
    if shown.returncode != 0:
        raise ApiError(f"{ref} has no {WORKFLOW}")
    workflow = hygiene.WorkflowReader(shown.stdout, f"{ref}:{WORKFLOW}").read()
    jobs = workflow.get("jobs")
    defined = dict(jobs.items()) if jobs is not None else {}
    problems = []
    unwatched = sorted(defined.keys() - MAX_AGE_DAYS.keys())
    if unwatched:
        problems.append(f"{WORKFLOW_FILE} defines job "
                        + ", ".join(f"`{key}`" for key in unwatched)
                        + ", which MAX_AGE_DAYS gives no age, so it would go unwatched")
    gone = sorted(MAX_AGE_DAYS.keys() - defined.keys())
    if gone:
        problems.append(f"{WORKFLOW_FILE} has no job "
                        + ", ".join(f"`{key}`" for key in gone)
                        + ", which MAX_AGE_DAYS watches, so it was renamed or deleted")
    if problems:
        raise ApiError("; ".join(problems) + ". Change the table with the workflow")
    names = {}
    for key in MAX_AGE_DAYS:
        name = defined[key].get("name")
        names[key] = name.value if name is not None and isinstance(name.value, str) else key
    return names


def on_main(sha: str, ref: str) -> bool:
    return git("merge-base", "--is-ancestor", sha, ref).returncode == 0


def last_successes(api, repository: str, ref: str, jobs: list[str]) -> dict[str, dict]:
    runs = [
        run
        for event in EVENTS
        for run in api.get(
            f"/repos/{repository}/actions/workflows/{WORKFLOW_FILE}/runs",
            event=event, status="completed", per_page="100",
        ).get("workflow_runs", [])
    ]
    runs.sort(key=lambda run: run.get("created_at", ""), reverse=True)
    found: dict[str, dict] = {}
    for run in runs:
        if len(found) == len(jobs):
            break
        sha = run.get("head_sha", "")
        if not on_main(sha, ref):
            continue
        listed = api.get(f"/repos/{repository}/actions/runs/{run['id']}/jobs",
                         filter="latest", per_page="100").get("jobs", [])
        for job in listed:
            name = job.get("name")
            if name in jobs and name not in found and job.get("conclusion") == "success":
                found[name] = {
                    "sha": sha,
                    "url": job.get("html_url") or run.get("html_url"),
                    "when": datetime.datetime.fromisoformat(
                        (job.get("completed_at") or run["created_at"]).replace("Z", "+00:00")),
                }
    return found


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
    api = evidence.Api(arguments.api_fixture)
    hygiene = evidence.load_hygiene()
    try:
        names = watched_jobs(hygiene, arguments.ref)
        found = last_successes(api, arguments.repository, arguments.ref, list(names.values()))
    except (ApiError, hygiene.UnreadableWorkflow) as error:
        print(f"check-real-install-evidence: {error}", file=sys.stderr)
        return 2

    lines = ["## Real-install evidence", ""]
    findings = []
    for key, name in names.items():
        days, remedy = MAX_AGE_DAYS[key]
        success = found.get(name)
        if success is None:
            lines.append(f"- **stale** `{name}`: no successful run on a main commit.")
            findings.append(
                f"- `{name}` has no successful run on a commit main contains that GitHub "
                f"still keeps. {remedy}"
            )
            continue
        age = now - success["when"]
        behind = git("rev-list", "--count", f"{success['sha']}..{arguments.ref}").stdout.strip()
        stamp = success["when"].strftime("%Y-%m-%d")
        state = "current" if age <= datetime.timedelta(days=days) else "stale"
        lines.append(f"- **{state}** `{name}`: succeeded {stamp} on `{success['sha']}` "
                     f"({behind} commits behind `{BRANCH}`), {success['url']}")
        if state == "stale":
            findings.append(
                f"- `{name}` last succeeded {stamp} on `{success['sha']}` ({success['url']}), "
                f"more than {days} days ago. {remedy}"
            )
    if arguments.findings:
        arguments.findings.write_text("\n".join(findings) + ("\n" if findings else ""),
                                      encoding="utf-8")
    report = "\n".join(lines) + "\n"
    print(report, end="")
    if arguments.report:
        arguments.report.write_text(report, encoding="utf-8")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
