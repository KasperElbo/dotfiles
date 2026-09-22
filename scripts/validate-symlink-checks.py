#!/usr/bin/env python3
"""Every `check_symlink` call site names the exact file Stow should have linked.

`check_symlink <link> <expected-root> [expected-source]` proves five things
without the third argument: the link exists, it is a symlink, its referent
exists, it canonicalises, and the referent is inside the expected package root.
None of those is "it points at the right file". A link redirected at another
file in the same package resolved under the expected root and was reported
green, so a manual mislink, a faulty migration or a Stow-layout regression
could send a configuration path at the wrong repository file and still pass
verification (issue #369).

The third argument is optional in the helper, which is what let the migration
proceed one platform at a time -- and equally what would let the weak form come
back unnoticed, because a two-argument call is not a syntax error and its
output is a tick like any other. This gate is the answer to "is the migration
finished", and it makes a new weak call site fail lint on the commit that adds
it rather than years later during an audit.

The suites under `tests/` are out of scope. `tests/test-verifier.sh` calls the
two-argument form on purpose, to prove the containment verdicts the helper
still owes when no source is given; demanding three arguments there would be
demanding that the helper's own contract test stop testing half of it. What
this gate is about is the call sites that verify a real machine.

Files still carrying the weak form are listed in MIGRATING with the exact
number of call sites left in them. An exact count rather than a floor, so that
neither direction is silent: adding a weak call site to a listed file fails,
and migrating one fails too, with the instruction to lower the number. The
entry must be removed when it reaches zero, so the list cannot outlive the
migration it describes.

Usage:
    scripts/validate-symlink-checks.py [--root DIR] [--migrating PATH=COUNT ...]

`--migrating` replaces the built-in list and exists so this checker's own
tests can point it at a fixture tree. A lint run passes neither flag.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import shell_files  # noqa: E402

HELPER = "check_symlink"
TEST_DIRECTORY = "tests/"
# The helper's own name, and not `check_symlink_owned`, which is a different
# function in common/verify-ai.sh with a different contract.
MENTION = re.compile(rf"(?<![A-Za-z0-9_]){HELPER}(?![A-Za-z0-9_])")

# The call sites not yet migrated, and how many each still has. Both Fedora
# verifiers carry open findings of their own (GAP-07, GAP-09, GAP-11, GAP-12),
# so they are migrated by the thread that fixes those rather than swept here.
MIGRATING = {
    "platforms/fedora/scripts/verify.sh": 18,
    "platforms/fedora-wsl/scripts/verify.sh": 11,
}

# A call, once its `\`-continued lines are joined: the helper at the start of a
# statement, then its arguments.
CALL = re.compile(rf"^\s*{HELPER}\s+(?P<arguments>\S.*)$")
# One double-quoted shell word. Every call site in this repository quotes every
# argument, because each one interpolates a path variable; an argument written
# any other way is reported rather than guessed at, so this cannot be fooled
# into counting a shape it does not understand.
ARGUMENT = re.compile(r'"(?:[^"\\]|\\.)*"')
DEFINITION = re.compile(rf"^\s*{HELPER}\s*\(\)")


def fail(message: str) -> None:
    print(f"symlink checks: {message}", file=sys.stderr)


def logical_lines(text: str) -> list[tuple[int, str]]:
    """The file's lines with `\\`-continuations joined, each with its number."""
    joined: list[tuple[int, str]] = []
    buffer = ""
    start = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if not buffer:
            start = number
        if line.endswith("\\"):
            buffer += line[:-1]
            continue
        joined.append((start, buffer + line))
        buffer = ""
    if buffer:
        joined.append((start, buffer))
    return joined


def call_sites(text: str) -> tuple[list[tuple[int, int]], list[int]]:
    """Each call's line number and argument count, plus unparseable lines.

    A mention of the helper that is neither its definition, nor a comment, nor
    a call this can count is returned as unparseable: a gate that quietly
    skipped what it did not recognise would be a gate the next unusual call
    site walks straight past.
    """
    counted: list[tuple[int, int]] = []
    unparseable: list[int] = []
    for number, line in logical_lines(text):
        if not MENTION.search(line):
            continue
        if DEFINITION.match(line) or line.lstrip().startswith("#"):
            continue
        match = CALL.match(line)
        if not match:
            unparseable.append(number)
            continue
        arguments = match.group("arguments")
        words = ARGUMENT.findall(arguments)
        if ARGUMENT.sub("", arguments).strip():
            unparseable.append(number)
            continue
        counted.append((number, len(words)))
    return counted, unparseable


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--migrating",
        action="append",
        metavar="PATH=COUNT",
        help="replace the built-in not-yet-migrated list; for this checker's own tests",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    migrating = dict(MIGRATING)
    if arguments.migrating is not None:
        migrating = {}
        for entry in arguments.migrating:
            if not entry:
                # An explicit empty list, which is what a tree with nothing
                # left to migrate looks like.
                continue
            name, _, count = entry.partition("=")
            if not name or not count.isdigit():
                fail(f"--migrating takes PATH=COUNT, not {entry!r}")
                return 1
            migrating[name] = int(count)

    errors = 0
    weak: dict[str, list[int]] = {}
    total = 0
    for name in shell_files(root):
        if name.startswith(TEST_DIRECTORY):
            continue
        path = root / name
        counted, unparseable = call_sites(path.read_text(encoding="utf-8"))
        for number in unparseable:
            fail(
                f"{name}:{number} mentions {HELPER} in a shape this gate cannot "
                f"read, so its arguments were not checked. Write the call as "
                f"one statement with every argument double-quoted, or teach "
                f"this checker the new shape."
            )
            errors += 1
        for number, count in counted:
            total += 1
            if count < 2:
                fail(f"{name}:{number} calls {HELPER} with {count} argument(s); it takes at least two")
                errors += 1
            elif count == 2:
                weak.setdefault(name, []).append(number)

    if total == 0:
        fail(f"no {HELPER} call sites were found at all; the check would pass vacuously")
        return 1

    for name, numbers in sorted(weak.items()):
        budget = migrating.get(name)
        if budget is None:
            lines = ", ".join(str(number) for number in numbers)
            fail(
                f"{name} calls {HELPER} without an expected source at line(s) "
                f"{lines}. Pass the exact repository file Stow should have "
                f"linked as the third argument, read off the package layout: "
                f'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" '
                f'"$DOTFILES_ROOT/zsh/.zshenv". Without it the check proves '
                f"only that the link lands somewhere inside the package."
            )
            errors += 1
        elif len(numbers) > budget:
            fail(
                f"{name} has {len(numbers)} two-argument {HELPER} call(s), up "
                f"from the {budget} this migration started with. Pass the "
                f"expected source at the new call site rather than raising the "
                f"number in {pathlib.Path(__file__).name}."
            )
            errors += 1

    for name, budget in sorted(migrating.items()):
        remaining = len(weak.get(name, []))
        if not (root / name).is_file():
            fail(f"the not-yet-migrated list names {name}, which does not exist; remove the entry")
            errors += 1
        elif remaining < budget:
            replacement = (
                f"lower it to {remaining}" if remaining else "remove the entry"
            )
            fail(
                f"{name} is down to {remaining} two-argument {HELPER} call(s) "
                f"from {budget}; {replacement} in "
                f"{pathlib.Path(__file__).name} so the list cannot outlive the "
                f"migration."
            )
            errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
