#!/usr/bin/env python3
"""Validate the dependency version-floor registry and its enforcement.

``config/tool-floors.tsv`` is the one place a documented minimum version is
stated. Before it existed, three documentation pages stated two different
Neovim minimums and nothing enforced either one, so this validator checks the
three ways that can regress:

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
3. **A pinned version falls below its own floor.** The mise configurations
   this repository provisions are the one place it controls an installed
   version, so a pin for a registry tool must satisfy that tool's floor;
   otherwise raising the floor leaves the machine provisioning less than the
   floor demands with the build still green.

Usage:
    scripts/validate-tool-floors.py [--root DIR]
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tomllib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402

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
    r"|(?P<newer>[0-9]+(?:\.[0-9]+)+)(?=\s+or\s+newer)"
    r"|at least\s+(?P<minimum>[0-9]+(?:\.[0-9]+)+)",
    re.IGNORECASE,
)
# A tool is named only when it stands alone: `nvim` inside `lazy.nvim` or
# `nvim-treesitter` is a plugin, not this registry's Neovim.
MENTION = r"(?<![\w.-])%s(?![\w-])"
TOOLCHAIN_DOC = pathlib.Path("docs") / "testing.md"
MISE_CONFIG = "*mise/config.toml"
# A mise key carries neither the spacing nor the major-version word a label
# does, so the tool this registry calls `python3` and labels `Python 3` is
# pinned as `python`.
LABEL_VERSION = re.compile(r"\s+[0-9]+(?:\.[0-9]+)*$")
# What starts a statement of its own: a list item, a table row, a heading. A
# blank line ends one. Everything else continues the statement above it, which
# is how a hard-wrapped sentence keeps the tool it named.
BLOCK_START = re.compile(r"^\s*(?:[-*+]\s|[0-9]+[.)]\s|\||#)")


def tracked(root: pathlib.Path, *patterns: str) -> list[pathlib.Path]:
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *patterns],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [root / name for name in listing.split("\0") if name]


def satisfies(version: str, minimum: str) -> bool:
    found = [int(part) for part in version.split(".")]
    floor = [int(part) for part in minimum.split(".")]
    width = max(len(found), len(floor))
    found += [0] * (width - len(found))
    floor += [0] * (width - len(floor))
    return found >= floor


def pin_keys(tool: str, label: str) -> set[str]:
    """The keys a mise configuration may pin this registry tool under."""
    return {tool.lower(), LABEL_VERSION.sub("", label).replace(" ", "").lower()}


def stated_floors(line: str) -> list[tuple[int, str]]:
    found = []
    for match in DOC_FLOOR.finditer(line):
        group = next(name for name, value in match.groupdict().items() if value)
        found.append((match.start(group), match.group(group)))
    return found


def blocks(lines: list[str]) -> list[list[tuple[int, str]]]:
    """The page split into statements, because a sentence wraps across lines.

    Prose here is hard-wrapped, so `Neovim ... requires 0.12 or newer` is one
    reword away from spanning two lines; attribution has to follow the
    statement the sentence lives in rather than the line the number landed on.
    A list item, a table row and a heading each start a statement of their own,
    so one bullet's floor is never read as the bullet above it.
    """
    found: list[list[tuple[int, str]]] = []
    current: list[tuple[int, str]] = []
    for number, raw in enumerate(lines, 1):
        if not raw.strip() or BLOCK_START.match(raw):
            if current:
                found.append(current)
                current = []
        if raw.strip():
            current.append((number, raw))
    if current:
        found.append(current)
    return found


def attributed_floors(
    block: list[tuple[int, str]], names: dict[str, str]
) -> tuple[list[tuple[int, str | None, str]], bool]:
    """Each minimum the block states, paired with the tool it is stated for.

    A minimum belongs to the nearest tool name or label written before it in
    the same paragraph, so `Neovim 0.12+ and Python 3.11+` states one floor for
    each of the two tools rather than both numbers for both tools. The owner is
    ``None`` when no registry tool is named before it; the second return value
    says whether the paragraph names a registry tool at all, which is how an
    unattributable floor is told apart from a floor for something the registry
    does not track, such as a kernel or a system Bash.
    """
    mentions: list[tuple[tuple[int, int], str]] = []
    floors: list[tuple[tuple[int, int], str]] = []
    for number, raw in block:
        lowered = raw.lower()
        for tool, label in names.items():
            for spelling in {tool.lower(), label.lower()}:
                for match in re.finditer(MENTION % re.escape(spelling), lowered):
                    mentions.append(((number, match.start()), tool))
        for column, version in stated_floors(raw):
            floors.append(((number, column), version))
    mentions.sort()
    attributed = []
    for position, version in sorted(floors):
        owner = None
        for start, tool in mentions:
            if start >= position:
                break
            owner = tool
        attributed.append((position[0], owner, version))
    return attributed, bool(mentions)


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
    try:
        rows = read_tsv(manifest, FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

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
    for path in tracked(root, "*.md"):
        page = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for block in blocks(lines):
            attributed, names_a_tool = attributed_floors(block, names)
            for number, tool, stated in attributed:
                if tool is None:
                    if not names_a_tool:
                        continue
                    fail(
                        f"{page}:{number} states a {stated} minimum before naming the "
                        f"tool it belongs to; name the tool before its floor so the "
                        f"registry can check it"
                    )
                    errors += 1
                    continue
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

    for path in tracked(root, MISE_CONFIG):
        config = path.relative_to(root).as_posix()
        with path.open("rb") as stream:
            pins = tomllib.load(stream).get("tools", {})
        for tool, minimum in floors.items():
            keys = pin_keys(tool, names[tool])
            for key, requested in pins.items():
                if key.lower() not in keys:
                    continue
                for entry in requested if isinstance(requested, list) else [requested]:
                    pinned = entry.get("version") if isinstance(entry, dict) else entry
                    if not isinstance(pinned, str) or not VERSION.match(pinned):
                        continue
                    if satisfies(pinned, minimum):
                        continue
                    fail(
                        f"{config} pins {key} {pinned}; {manifest.name} requires "
                        f"{tool} {minimum} or newer"
                    )
                    errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
