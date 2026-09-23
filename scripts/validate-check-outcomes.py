#!/usr/bin/env python3
"""Prove that a verifier's checks can fail, not only that they exist.

Every other gate in this repository reads files. This one cannot: whether a
`check_*` call site is able to fail is a statement about what ran. A predicate
that is always true and one that happens to be true on this machine are the
same text, and the audit's own reproduction was a check inserted into a
verifier that no gate anywhere noticed (GRADE-03 of #393).

So `common/lib/verify.sh` records, for each verdict it prints, the call site in
the verifier that produced it, and this reads that trace after the default
suites have run. A call site that produced both a pass and a fail is covered:
some fixture drove it each way, so inverting its predicate takes one of those
outcomes away and this turns red.

The remaining call sites are the ones no fixture has driven both ways yet, and
`config/check-outcomes.tsv` names each of them with the reason it is allowed.
An exception belongs to one call site, not to its verifier: when it was a count,
a check could lose its failing fixture while another gained one and the count,
and the gate, stayed the same (#497). So a call site this run left uncovered is
refused unless its own row excuses it, and every row carries a reason.

A row names its call by what it says, not by its line. Verifiers change all the
time, and a line number would move an exception onto whatever call slid into
its place; the call's text only changes when the call does. The text is the
whole command, continuation lines joined and whitespace collapsed, without the
`if`, `while`, `until` or `!` in front of it or the `; then` behind it. A call
that appears more than once in a verifier is told apart by its occurrence.

A row whose call is now covered is reported rather than refused, because the
trace reads behaviour, which is not the same everywhere: a machine with
`podman` or `systemctl` drives checks to a verdict that a machine without them
reports as not observed. So the rows are the worst environment's, coverage
beyond them is reported, and `--record` rewrites the rows from a trace, keeping
the reasons already written. A row naming a call the verifier no longer makes
is refused: that reads files, which are the same everywhere.

The trace records the path the shell actually sourced, and only the repository's
own files are counted. A suite that copies the tree somewhere and mutates the
copy is proving something about the mutation, not about the verifier, and its
outcomes must not make a call site look covered.
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
from typing import NamedTuple

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = ROOT / "config" / "check-outcomes.tsv"
FIELDS = ("verifier", "call", "reason")

# A `check_*` call in command position. A verifier writes one bare, behind `if`
# or negated, and the shared reader is not used here because the trace decides
# what is covered; this only has to find the call sites to count them. A line
# defining a verifier's own check_* helper is not a call: nothing is ever
# traced to it, so counting it held ten sites uncovered for good.
CHECK_CALL = re.compile(
    r"^\s*(?:(?:if|while|until)\s+)?(?:!\s+)?(check_[a-z0-9_]+)\b(?!\s*\(\))"
)

# A call whose first argument starts on the next line. Bash credits such a call
# to the line its first argument is on, so the trace names a line this gate
# does not count, and the call site stays uncovered whatever a fixture does.
SPLIT_CALL = re.compile(r"^\s*(?:(?:if|while|until)\s+)?(?:!\s+)?check_[a-z0-9_]+\s*\\$")

VERIFIER_GLOBS = ("platforms/*/scripts/verify*.sh", "common/verify-*.sh")


def fail(message: str) -> None:
    print(f"check outcomes: {message}", file=sys.stderr)


def verifiers() -> list[str]:
    found: set[str] = set()
    for pattern in VERIFIER_GLOBS:
        found.update(str(path.relative_to(ROOT)) for path in ROOT.glob(pattern))
    return sorted(found)


class Site(NamedTuple):
    """One `check_*` call: where it is today, and what it is."""

    line: int
    call: str


def call_text(lines: list[str], index: int) -> str:
    """The call starting at `lines[index]`, as a row in the ledger names it."""
    parts = [lines[index]]
    while parts[-1].rstrip().endswith("\\") and index + 1 < len(lines):
        parts[-1] = parts[-1].rstrip()[:-1]
        index += 1
        parts.append(lines[index])
    text = " ".join(" ".join(parts).split())
    text = re.sub(r"^(?:(?:if|while|until)\s+)?(?:!\s+)?", "", text)
    return re.sub(r"\s*;\s*(?:then|do)$", "", text)


def call_sites(verifier: str) -> list[Site]:
    """Every `check_*` call in a verifier, comments dropped.

    A call made more than once in one verifier is told apart by its
    occurrence, counted from the top, so a row can excuse one of them.
    """
    lines = (ROOT / verifier).read_text(encoding="utf-8").splitlines()
    seen: collections.Counter[str] = collections.Counter()
    sites = []
    for index, line in enumerate(lines):
        if line.lstrip().startswith("#") or not CHECK_CALL.match(line):
            continue
        call = call_text(lines, index)
        seen[call] += 1
        if seen[call] > 1:
            call = f"{call} (occurrence {seen[call]})"
        sites.append(Site(index + 1, call))
    return sites


def read_trace(path: pathlib.Path) -> dict[tuple[str, int], set[str]]:
    """The outcomes each call site produced, keyed by verifier and line.

    A frame is counted only when it resolves to a file inside the repository
    and is one of the declared verifiers; a scratch copy under a suite's
    temporary directory resolves elsewhere and is dropped.
    """
    known = set(verifiers())
    outcomes: dict[tuple[str, int], set[str]] = collections.defaultdict(set)
    for entry in path.read_text(encoding="utf-8").splitlines():
        frame, _, rest = entry.partition("\t")
        number, _, outcome = rest.partition("\t")
        if not number.isdigit():
            continue
        try:
            relative = str(pathlib.Path(frame).resolve().relative_to(ROOT))
        except ValueError:
            continue
        if relative in known:
            outcomes[(relative, int(number))].add(outcome)
    return outcomes


def read_ledger() -> dict[tuple[str, str], str] | None:
    """The excused call sites, each with the reason it is allowed."""
    rows: dict[tuple[str, str], str] = {}
    ledger = LEDGER.relative_to(ROOT)
    lines = LEDGER.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].split("\t") != list(FIELDS):
        fail(f"{ledger}: the header must be {chr(9).join(FIELDS)}")
        return None
    errors = 0
    for number, line in enumerate(lines[1:], 2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != len(FIELDS):
            fail(f"{ledger}:{number}: expected {len(FIELDS)} columns")
            return None
        verifier, call, reason = cells
        if (verifier, call) in rows:
            fail(f"{ledger}:{number}: {verifier} `{call}` is already excused above")
            errors += 1
        if not reason.strip():
            fail(
                f"{ledger}:{number}: {verifier} `{call}` has no reason; an "
                f"exception to this rule says why the check is allowed to be "
                f"one no fixture can fail"
            )
            errors += 1
        rows[(verifier, call)] = reason
    return None if errors else rows


def covered(outcomes: dict[tuple[str, int], set[str]], verifier: str, site: Site) -> bool:
    return {"pass", "fail"} <= outcomes.get((verifier, site.line), set())


def record(outcomes: dict[tuple[str, int], set[str]]) -> int:
    """Rewrite the ledger from a trace, keeping the reasons already written."""
    reasons: dict[tuple[str, str], str] = {}
    lines = LEDGER.read_text(encoding="utf-8").splitlines() if LEDGER.exists() else []
    if lines and lines[0].split("\t") == list(FIELDS):
        for line in lines[1:]:
            cells = line.split("\t")
            if len(cells) == len(FIELDS):
                reasons[(cells[0], cells[1])] = cells[2]
    rows = ["\t".join(FIELDS)]
    unexplained = 0
    for verifier in verifiers():
        for site in call_sites(verifier):
            if covered(outcomes, verifier, site):
                continue
            reason = reasons.get((verifier, site.call), "")
            unexplained += not reason.strip()
            rows.append(f"{verifier}\t{site.call}\t{reason}")
    LEDGER.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(f"Wrote {LEDGER.relative_to(ROOT)}: {len(rows) - 1} uncovered call sites.")
    if unexplained:
        print(
            f"{unexplained} of them have no reason yet; write one in the "
            f"reason column, or the next run refuses the row."
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", help="the file DOTFILES_VERIFY_TRACE was set to")
    parser.add_argument(
        "--record",
        action="store_true",
        help="write config/check-outcomes.tsv from this trace instead of checking "
             "against it, for the first run and after fixtures are added",
    )
    arguments = parser.parse_args()

    trace_path = pathlib.Path(arguments.trace)
    if not trace_path.is_file():
        fail(
            f"{arguments.trace} does not exist, so no verdict was recorded; the "
            f"default run sets DOTFILES_VERIFY_TRACE before the suites start"
        )
        return 1

    outcomes = read_trace(trace_path)
    if not outcomes:
        fail(
            "the trace names no call site in any verifier, so this check would "
            "pass for want of evidence; DOTFILES_VERIFY_TRACE reached no verifier"
        )
        return 1

    if arguments.record:
        return record(outcomes)

    excused = read_ledger()
    if excused is None:
        return 1

    errors = 0
    ledger = LEDGER.relative_to(ROOT)
    sites = {verifier: call_sites(verifier) for verifier in verifiers()}
    for verifier, found in sites.items():
        lines = (ROOT / verifier).read_text(encoding="utf-8").splitlines()
        for site in found:
            if SPLIT_CALL.match(lines[site.line - 1]):
                fail(
                    f"{verifier}:{site.line}: the call's first argument is on "
                    f"the next line, and bash credits the call to that line, "
                    f"so no fixture can cover this one; start its arguments on "
                    f"the line that names the check"
                )
                errors += 1

    gained: list[tuple[str, Site]] = []
    for verifier, found in sites.items():
        for site in found:
            is_excused = (verifier, site.call) in excused
            if covered(outcomes, verifier, site):
                if is_excused:
                    gained.append((verifier, site))
            elif not is_excused:
                fail(
                    f"{verifier}:{site.line}: `{site.call}` was never driven to "
                    f"both a pass and a fail by the default suites, and "
                    f"{ledger} does not excuse it. A check no fixture can fail "
                    f"proves nothing. Give it a failing fixture, or add a row "
                    f"for it with the reason"
                )
                errors += 1

    calls = {(verifier, site.call) for verifier, found in sites.items() for site in found}
    for verifier, call in sorted(set(excused) - calls):
        fail(
            f"{ledger} excuses `{call}` in {verifier}, which makes no such "
            f"call; the call was changed, moved or removed, so change or "
            f"delete its row"
        )
        errors += 1

    if errors:
        return 1

    for verifier, site in gained:
        print(
            f"check outcomes: {verifier}:{site.line}: `{site.call}` was driven "
            f"to both a pass and a fail, but {ledger} still excuses it; delete "
            f"its row, or re-record with --record, to keep the gain"
        )

    total = sum(len(found) for found in sites.values())
    count = sum(
        covered(outcomes, verifier, site)
        for verifier, found in sites.items()
        for site in found
    )
    print(f"Check-outcome coverage: {count} of {total} check_* call sites "
          f"were driven to both a pass and a fail.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
