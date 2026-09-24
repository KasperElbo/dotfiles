#!/usr/bin/env python3
"""Report the self-hosted real-install jobs that have not succeeded recently.

The Fedora WSL and Parrot VM jobs in real-install.yml run on Kasper's own
machines, so they run only when someone dispatches them; the weekly schedule
skips them (#501). Nothing else notices when they stop being run, so their
last success can quietly become months old while main keeps changing.

For every job in the workflow that runs on a `self-hosted` runner, this finds
the newest dispatched run in which that job concluded `success` on a commit
main contains, and reports its date, its commit and how many commits main has
gained since. A job is:

  current   it succeeded within MAX_AGE_DAYS;
  stale     its newest success is older than that, or it has none GitHub still
            keeps a record of.

The jobs are read from the workflow on --ref, so a self-hosted job added later
is covered without this changing. Runs on a branch main does not contain are
not evidence for main and are skipped.

Exit status: 0 when every self-hosted job is current, 1 otherwise, 2 on a usage
or API error.

Usage:
    scripts/check-self-hosted-evidence.py --repository OWNER/NAME [--ref REF]
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
# Once a month: often enough that a regression on these machines is found
# within a few weeks of the change that caused it.
MAX_AGE_DAYS = 30


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evidence = load("main_evidence", "check-main-evidence.py")
git = evidence.git
ApiError = evidence.ApiError


def self_hosted_jobs(hygiene, ref: str) -> list[str]:
    """The display names of the jobs the workflow on REF runs on its own runners."""
    shown = git("show", f"{ref}:{WORKFLOW}")
    if shown.returncode != 0:
        raise ApiError(f"{ref} has no {WORKFLOW}")
    workflow = hygiene.WorkflowReader(shown.stdout, f"{ref}:{WORKFLOW}").read()
    names = []
    for key, job in workflow.get("jobs").items() if workflow.get("jobs") else []:
        runs_on = job.get("runs-on")
        labels = runs_on.value if runs_on is not None else None
        labels = [label.value for label in labels] if isinstance(labels, list) else [labels]
        if "self-hosted" in labels:
            name = job.get("name")
            names.append(name.value if name is not None and isinstance(name.value, str) else key)
    if not names:
        raise ApiError(f"{ref}:{WORKFLOW} has no self-hosted job, so there is nothing to check")
    return names


def on_main(sha: str, ref: str) -> bool:
    return git("merge-base", "--is-ancestor", sha, ref).returncode == 0


def last_successes(api, repository: str, ref: str, jobs: list[str]) -> dict[str, dict]:
    runs = api.get(
        f"/repos/{repository}/actions/workflows/{WORKFLOW_FILE}/runs",
        event="workflow_dispatch", status="completed", per_page="100",
    ).get("workflow_runs", [])
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
        jobs = self_hosted_jobs(hygiene, arguments.ref)
        found = last_successes(api, arguments.repository, arguments.ref, jobs)
    except (ApiError, hygiene.UnreadableWorkflow) as error:
        print(f"check-self-hosted-evidence: {error}", file=sys.stderr)
        return 2

    lines = ["## Self-hosted real-install evidence", ""]
    findings = []
    for name in jobs:
        success = found.get(name)
        if success is None:
            lines.append(f"- **stale** `{name}`: no successful dispatched run on a main commit.")
            findings.append(
                f"- `{name}` has no successful run on a commit main contains that GitHub "
                "still keeps. Dispatch real-install.yml on main with its input set."
            )
            continue
        age = now - success["when"]
        behind = git("rev-list", "--count", f"{success['sha']}..{arguments.ref}").stdout.strip()
        stamp = success["when"].strftime("%Y-%m-%d")
        state = "current" if age <= datetime.timedelta(days=MAX_AGE_DAYS) else "stale"
        lines.append(f"- **{state}** `{name}`: succeeded {stamp} on `{success['sha']}` "
                     f"({behind} commits behind `{BRANCH}`), {success['url']}")
        if state == "stale":
            findings.append(
                f"- `{name}` last succeeded {stamp} on `{success['sha']}` ({success['url']}), "
                f"more than {MAX_AGE_DAYS} days ago. Dispatch real-install.yml on main with "
                "its input set."
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
