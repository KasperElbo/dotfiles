#!/usr/bin/env python3
"""Give every tracked shell file exactly one role, and enforce its file mode.

An executable bit is a contract: it says "this file is an entry point you may
run". A sourced library that carries it invites someone to execute it, which
either does nothing or does something surprising; an entry point that lacks it
fails for whoever types its path. Both had accumulated in this repository.

`config/shell-file-roles.tsv` is the inventory. Every tracked shell file — and
every tracked file under a stowed `bin` directory, which becomes a command on
PATH — must match exactly one pattern there and carry that role's mode.
"Exactly one" is deliberate: an overlapping pattern is an ambiguity in the
inventory, not something to resolve by first-match order.

Usage:
    scripts/validate-shell-file-roles.py [--root DIR]
"""

from __future__ import annotations

import argparse
import csv
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import SHELL_FILE_ROLES_MANIFEST as MANIFEST  # noqa: E402
from manifests import role_pattern_matches as matches  # noqa: E402

FIELDS = ["role", "mode", "pattern", "description"]


def tracked(root: pathlib.Path) -> list[str]:
    """Tracked files only.

    A filesystem walk is not a substitute: this policy is about what the
    repository ships, so an unreadable index is an error to report, not
    something to paper over with a different file set.
    """
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(
            f"shell-file roles: cannot list tracked files in {root}: "
            f"{result.stderr.strip() or f'git exited {result.returncode}'}"
        )
    return [name for name in result.stdout.split("\0") if name]


def governed(name: str) -> bool:
    """Files whose executable bit this repository is responsible for."""
    if name.endswith((".sh", ".zsh", ".ps1")):
        return True
    if "/.local/bin/" in name or name.startswith("bin/.local/bin/"):
        return True
    if name.startswith("scripts/") and name.endswith(".py"):
        return True
    return name in {"doctor", "zsh/.zshenv"} or name.startswith("zsh/.config/zsh/")


def is_exact(pattern: str) -> bool:
    return not any(character in pattern for character in "*?[")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    with (root / MANIFEST).open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE)
        if reader.fieldnames != FIELDS:
            print(f"shell-file roles: unexpected columns: {reader.fieldnames}", file=sys.stderr)
            return 1
        rules = list(reader)

    problems: list[str] = []
    for rule in rules:
        if rule["mode"] not in {"644", "755"}:
            problems.append(f"rule {rule['pattern']!r}: mode must be 644 or 755")
        if not rule["description"] or rule["description"] == "-":
            problems.append(f"rule {rule['pattern']!r}: every role needs a description")

    used: set[str] = set()
    for name in tracked(root):
        if not governed(name):
            continue
        applicable = [rule for rule in rules if matches(rule["pattern"], name)]
        if not applicable:
            problems.append(
                f"{name}: no role in {MANIFEST} claims this file; classify it before adding it"
            )
            continue
        # A rule naming one exact file is more specific than any glob over it.
        exact = [rule for rule in applicable if is_exact(rule["pattern"])]
        if len(exact) == 1:
            rule = exact[0]
        elif len(applicable) == 1:
            rule = applicable[0]
        else:
            patterns = ", ".join(item["pattern"] for item in applicable)
            problems.append(f"{name}: matches more than one role pattern ({patterns})")
            continue
        for item in applicable:
            used.add(item["pattern"])
        actual = oct((root / name).stat().st_mode & 0o777)[2:]
        if actual != rule["mode"]:
            problems.append(
                f"{name}: mode {actual}, but its role {rule['role']!r} requires {rule['mode']} "
                f"({rule['description']})"
            )

    for rule in rules:
        if rule["pattern"] not in used:
            problems.append(
                f"rule {rule['pattern']!r} matches nothing; remove it rather than leaving a "
                "rule that can never fail"
            )

    for problem in problems:
        print(f"shell-file roles: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
