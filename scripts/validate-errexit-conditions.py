#!/usr/bin/env python3
"""Refuse a `set -e` that is issued where it cannot take effect.

Bash suppresses errexit for every command that runs as a condition: the test
of an `if`, `elif`, `while` or `until`, anything negated with `!`, and every
command of an `&&` or `||` list except the last. The suppression reaches into
a subshell run in that position, and a `set -e` issued inside the subshell
does not bring it back:

    if ! ( set -euo pipefail; false; echo reached ); then ...   # prints reached

The subshell then reports only the status of its last command.
common/lib/bootstrap-tools.sh installed the pinned mise and Starship releases
in exactly that shape, and a tar that extracted the binary and then failed was
carried past to a successful install (#539, V5-20). The `set -euo pipefail`
read as the guarantee that a failed step stops the run, and it was the one
line in the block doing nothing.

So this refuses the shape rather than the one instance: a subshell whose first
command turns errexit on, sitting in a condition. The fix is a guard on each
fallible step (`step || die ...`), as scripts/scan-secrets.sh does, and the
inert `set -e` goes, so the block no longer claims what it does not do.

The file is read with scripts/lib/shell.py, so a heredoc, a string or a
comment showing the shape -- this repository's tests write several -- is not
code and is not refused.

Usage:
    scripts/validate-errexit-conditions.py [--root DIR] [FILE ...]

With no FILE, every file ./scripts/lint.sh checks is read.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import shell_files  # noqa: E402
from shell import UnreadableShell, blank_text, without_case_patterns  # noqa: E402

# A subshell opening: `(` that is not `$(`, `<(`, `>(` or `((`, and not an
# array literal after `=`.
OPEN = re.compile(r"(?<![$<>=(])\((?!\()")
# The first command inside it turns errexit on: `set -e`, `set -euo pipefail`,
# `set -o errexit`, in any flag order.
ERREXIT = re.compile(r"\A\s*set\b[^;&|\n]*?\s(?:-[A-Za-z]*e[A-Za-z]*|-o\s+errexit)\b")
# What precedes the `(` when it is in a condition. An `&&` or `||` before it
# is not one: the last command of a list runs with errexit in force.
CONDITION_BEFORE = re.compile(r"(?:\b(?:if|elif|while|until)|!)\s*\Z")
# What follows the matching `)` when the subshell is the left side of a list.
LIST_AFTER = re.compile(r"\A[ \t]*(?:&&|\|\|)")


def closing(code: str, start: int) -> int:
    """The index of the `)` matching the `(` at `start`."""
    depth = 0
    for index in range(start, len(code)):
        character = code[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index
    raise UnreadableShell(f"the subshell opened at offset {start} is never closed")


def line_of(code: str, index: int) -> int:
    return code.count("\n", 0, index) + 1


def problems_in(name: str, text: str) -> list[str]:
    code = without_case_patterns(blank_text(text))
    found: list[str] = []
    for match in OPEN.finditer(code):
        start = match.start()
        if not ERREXIT.search(code[start + 1 :]):
            continue
        end = closing(code, start)
        before = CONDITION_BEFORE.search(code[:start])
        after = LIST_AFTER.search(code[end + 1 :])
        if before is None and after is None:
            continue
        opener = before.group(0).strip() if before else after.group(0).strip()
        where = (
            f"the left side of an `{opener}` list" if opener in ("&&", "||")
            else f"a condition (`{opener} (`)"
        )
        found.append(
            f"{name}:{line_of(code, start)}: this subshell turns errexit on, but it "
            f"runs as {where}, where Bash suppresses errexit and `set -e` inside "
            "does not restore it; only its last command's status is reported. "
            "Guard each fallible step with `|| die ...` and drop the inert `set -e`."
        )
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    parser.add_argument("files", nargs="*", type=pathlib.Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    if arguments.files:
        paths = [(str(path), path) for path in arguments.files]
    else:
        paths = [(name, root / name) for name in shell_files(root)]

    problems: list[str] = []
    for name, path in paths:
        try:
            problems.extend(problems_in(name, path.read_text(encoding="utf-8")))
        except UnreadableShell as error:
            problems.append(f"{name}: cannot be read as shell: {error}")
        except (OSError, UnicodeDecodeError) as error:
            problems.append(f"{name}: cannot be read: {error}")

    for problem in problems:
        print(f"errexit conditions: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
