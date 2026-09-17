#!/usr/bin/env python3
"""Validate the dependency version-floor registry and its enforcement.

``config/tool-floors.tsv`` is the one place a documented minimum version is
stated. Before it existed, three documentation pages stated two different
Neovim minimums and nothing enforced either one, so this validator checks the
two ways that can regress:

1. **Nobody enforces the floor.** Every consumer a row names must exist and
   must actually read the floor through ``tool_floor``/``tool_floor_check``. A
   consumer that hardcodes the number instead stops tracking the table, which
   is how the floors drifted apart in the first place.
2. **The documentation disagrees with the table.** Every page that states a
   minimum for a tool the registry knows -- in ``>= 0.12``, ``0.12+``,
   ``0.12 or newer`` or ``at least 0.12`` form, wherever it is written -- must
   state the registry's floor, and ``docs/testing.md`` must state every floor,
   so a new floor cannot be added without documenting it and a documented one
   cannot drift on a page nobody remembered to update.

Usage:
    scripts/validate-tool-floors.py [--root DIR]
"""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import re
import subprocess
import sys

FIELDS = ["tool", "min_version", "requirement", "consumers"]
VERSION = re.compile(r"^[0-9]+(\.[0-9]+)*$")
# The reader every enforcer must go through; naming either function proves the
# file resolves the floor rather than restating it.
READER = re.compile(r"\btool_floor(?:_check)?\b")
# A row of the contributor-toolchain table: `| Neovim (`nvim`) | >= 0.12 | … |`.
# Its tool cell is also where prose learns to spell the tool: `Neovim`.
DOC_ROW = re.compile(r"^\|(?P<tool>[^|]+)\|(?P<minimum>[^|]+)\|")
LABEL_NOISE = re.compile(r"\([^)]*\)|`[^`]*`")
# How documentation states a minimum, in any page: `>= 0.12`, `0.12+`,
# `0.12 or newer`, `at least 0.12`. A bare version (a pin such as `0.12.5`) is
# not a floor and is deliberately not matched.
DOC_FLOOR = re.compile(
    r">=\s*(?P<least>[0-9]+(?:\.[0-9]+)+)"
    r"|(?P<plus>[0-9]+(?:\.[0-9]+)+)\s*\+"
    r"|(?P<newer>[0-9]+(?:\.[0-9]+)+)(?=\s+or\s+(?:newer|later|above))"
    r"|(?:at least|minimum(?: version)?)\s+(?P<minimum>[0-9]+(?:\.[0-9]+)+)",
    re.IGNORECASE,
)
# A tool is named only when it stands alone: `nvim` inside `lazy.nvim` or
# `nvim-treesitter` is a plugin, not this registry's Neovim.
MENTION = r"(?<![\w.-])%s(?![\w-])"
TOOLCHAIN_DOC = pathlib.Path("docs") / "testing.md"


def tracked_markdown(root: pathlib.Path) -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [root / name for name in listing.split("\0") if name]


def stated_floors(line: str) -> list[tuple[int, str]]:
    found = []
    for match in DOC_FLOOR.finditer(line):
        group = next(name for name, value in match.groupdict().items() if value)
        found.append((match.start(group), match.group(group)))
    return found


def attributed_floors(line: str, names: dict[str, str]) -> list[tuple[str, str]]:
    """Each minimum the line states, paired with the tool it is stated for.

    A minimum belongs to the nearest tool name or label written before it, so
    `Neovim 0.12+ and Python 3.11+` states one floor for each of the two tools
    rather than both numbers for both tools.
    """
    lowered = line.lower()
    mentions = sorted(
        (match.start(), tool)
        for tool, label in names.items()
        for spelling in {tool.lower(), label.lower()}
        for match in re.finditer(MENTION % re.escape(spelling), lowered)
    )
    attributed = []
    for position, version in stated_floors(line):
        owner = None
        for start, tool in mentions:
            if start >= position:
                break
            owner = tool
        if owner is not None:
            attributed.append((owner, version))
    return attributed


def fail(message: str) -> None:
    print(f"tool floors: {message}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    arguments = parser.parse_args()

    root = (
        pathlib.Path(arguments.root).resolve()
        if arguments.root
        else pathlib.Path(__file__).resolve().parents[1]
    )
    manifest = pathlib.Path(
        os.environ.get("TOOL_FLOOR_MANIFEST", root / "config" / "tool-floors.tsv")
    )

    errors = 0
    with manifest.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != FIELDS:
            fail(f"unexpected columns: {reader.fieldnames}")
            return 1
        rows = list(reader)

    if not rows:
        fail(f"{manifest} declares no floors")
        return 1

    seen: set[str] = set()
    floors: dict[str, str] = {}
    for line, row in enumerate(rows, 2):
        tool = (row["tool"] or "").strip()
        minimum = (row["min_version"] or "").strip()
        requirement = (row["requirement"] or "").strip()

        if not tool:
            fail(f"line {line}: row has no tool")
            errors += 1
            continue
        if tool in seen:
            fail(f"line {line}: duplicate tool {tool!r}")
            errors += 1
        seen.add(tool)
        if not VERSION.match(minimum):
            fail(f"line {line}: {tool} has an unusable min_version {minimum!r}")
            errors += 1
            continue
        if not requirement:
            fail(f"line {line}: {tool} does not say why {minimum} is required")
            errors += 1
        floors[tool] = minimum

        consumers = [name.strip() for name in row["consumers"].split(",") if name.strip()]
        if not consumers:
            fail(f"line {line}: {tool} names nothing that enforces its floor")
            errors += 1
        for consumer in consumers:
            path = root / consumer
            if not path.is_file():
                fail(f"line {line}: {tool} names a missing consumer: {consumer}")
                errors += 1
                continue
            text = path.read_text(encoding="utf-8")
            if not READER.search(text):
                fail(
                    f"{consumer} is named as enforcing the {tool} floor but never reads "
                    f"it; call tool_floor/tool_floor_check instead of restating {minimum}"
                )
                errors += 1

    labels: dict[str, str] = {}
    for raw_line in (root / TOOLCHAIN_DOC).read_text(encoding="utf-8").splitlines():
        match = DOC_ROW.match(raw_line)
        if match is None:
            continue
        cell = match.group("tool")
        for tool in floors:
            if f"`{tool}`" in cell:
                labels[tool] = LABEL_NOISE.sub("", cell).strip() or tool

    toolchain = TOOLCHAIN_DOC.as_posix()
    names = {tool: labels.get(tool, tool) for tool in floors}
    stated_in_toolchain: set[str] = set()
    for path in tracked_markdown(root):
        page = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, raw in enumerate(lines, 1):
            for tool, stated in attributed_floors(raw, names):
                minimum = floors[tool]
                if stated == minimum:
                    if page == toolchain:
                        stated_in_toolchain.add(tool)
                    continue
                fail(
                    f"{page}:{number} states {stated} as the {tool} minimum; "
                    f"{manifest.name} says {minimum}"
                )
                errors += 1

    for tool, minimum in floors.items():
        if tool not in stated_in_toolchain:
            fail(
                f"{toolchain} does not state the {tool} floor "
                f"({minimum}); every floor belongs in its toolchain table"
            )
            errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
