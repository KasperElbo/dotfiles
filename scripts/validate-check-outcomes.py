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

The remaining call sites are the ones no fixture has driven both ways yet.
There are too many to fix in one change, so `config/check-outcomes.tsv` records
how many each verifier still has, and the count may fall but never rise. A new
check with no fixture behind it raises its verifier's count and is refused; a
check that gains one lowers the count, and the recorded number has to come down
with it, the same ratchet `scripts/validate-symlink-checks.py` uses.

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

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = ROOT / "config" / "check-outcomes.tsv"
FIELDS = ("verifier", "uncovered", "note")

# A `check_*` call in command position. A verifier writes one bare, behind `if`
# or negated, and the shared reader is not used here because the trace decides
# what is covered; this only has to find the call sites to count them.
CHECK_CALL = re.compile(r"^\s*(?:(?:if|while|until)\s+)?(?:!\s+)?(check_[a-z0-9_]+)\b")

VERIFIER_GLOBS = ("platforms/*/scripts/verify*.sh", "common/verify-*.sh")


def fail(message: str) -> None:
    print(f"check outcomes: {message}", file=sys.stderr)


def verifiers() -> list[str]:
    found: set[str] = set()
    for pattern in VERIFIER_GLOBS:
        found.update(str(path.relative_to(ROOT)) for path in ROOT.glob(pattern))
    return sorted(found)


def call_sites(verifier: str) -> list[int]:
    """The line of every `check_*` call in a verifier, comments dropped."""
    lines = (ROOT / verifier).read_text(encoding="utf-8").splitlines()
    return [
        number
        for number, line in enumerate(lines, 1)
        if not line.lstrip().startswith("#") and CHECK_CALL.match(line)
    ]


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


def read_ledger() -> dict[str, int] | None:
    rows: dict[str, int] = {}
    lines = LEDGER.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].split("\t") != list(FIELDS):
        fail(f"{LEDGER.relative_to(ROOT)}: the header must be {chr(9).join(FIELDS)}")
        return None
    for number, line in enumerate(lines[1:], 2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != len(FIELDS):
            fail(f"{LEDGER.relative_to(ROOT)}:{number}: expected {len(FIELDS)} columns")
            return None
        verifier, uncovered, _ = cells
        if not uncovered.isdigit():
            fail(f"{LEDGER.relative_to(ROOT)}:{number}: {uncovered!r} is not a count")
            return None
        rows[verifier] = int(uncovered)
    return rows


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
        rows = ["\t".join(FIELDS)]
        for verifier in verifiers():
            sites = call_sites(verifier)
            if not sites:
                continue
            uncovered = sum(
                1
                for line in sites
                if not {"pass", "fail"} <= outcomes.get((verifier, line), set())
            )
            rows.append(f"{verifier}\t{uncovered}\t{len(sites)} check_* call sites")
        LEDGER.write_text("\n".join(rows) + "\n", encoding="utf-8")
        print(f"Wrote {LEDGER.relative_to(ROOT)} from {arguments.trace}.")
        return 0

    recorded = read_ledger()
    if recorded is None:
        return 1

    errors = 0
    ledger = LEDGER.relative_to(ROOT)
    for verifier in verifiers():
        sites = call_sites(verifier)
        if not sites:
            if verifier in recorded:
                fail(f"{ledger} records {verifier}, which calls no check_*")
                errors += 1
            continue
        if verifier not in recorded:
            fail(
                f"{verifier} calls check_* {len(sites)} times but {ledger} does "
                f"not record it; every verifier answers to this rule"
            )
            errors += 1
            continue
        uncovered = [
            line
            for line in sites
            if not {"pass", "fail"} <= outcomes.get((verifier, line), set())
        ]
        allowed = recorded[verifier]
        if len(uncovered) > allowed:
            listed = ", ".join(f"{verifier}:{line}" for line in uncovered)
            fail(
                f"{verifier}: {len(uncovered)} check_* call sites were never "
                f"driven to both a pass and a fail by the default suites, and "
                f"{ledger} allows {allowed}. A check no fixture can fail proves "
                f"nothing. Give the new one a failing fixture, or raise the "
                f"count with the reason. The sites are: {listed}"
            )
            errors += 1
        elif len(uncovered) < allowed:
            fail(
                f"{verifier}: {len(uncovered)} check_* call sites are still "
                f"uncovered but {ledger} allows {allowed}; lower it to "
                f"{len(uncovered)} so the ratchet keeps what this gained"
            )
            errors += 1
    for verifier in sorted(set(recorded) - set(verifiers())):
        fail(f"{ledger} records {verifier}, which is not a verifier in this tree")
        errors += 1

    if errors:
        return 1
    covered = sum(
        1
        for verifier in verifiers()
        for line in call_sites(verifier)
        if {"pass", "fail"} <= outcomes.get((verifier, line), set())
    )
    total = sum(len(call_sites(verifier)) for verifier in verifiers())
    print(f"Check-outcome coverage: {covered} of {total} check_* call sites "
          f"were driven to both a pass and a fail.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
