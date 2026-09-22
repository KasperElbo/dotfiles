#!/usr/bin/env python3
"""Validate the dependency version-floor registry and its enforcement.

``config/tool-floors.tsv`` is the one place a documented minimum version is
stated for a tool this repository's toolchain preflights; ``docs/testing.md``
names the two floors deliberately kept outside it. Before it existed, three documentation pages stated two different
Neovim minimums and nothing enforced either one, so this validator checks the
three ways that can regress:

1. **Nobody enforces the floor.** Every consumer a row names must exist and
   must actually read the floor through one of the reader functions
   ``common/lib/tool-floors.sh`` defines. A consumer that hardcodes the number
   instead stops tracking the table, which is how the floors drifted apart in
   the first place.

   This is checked by reading the consumer as shell rather than as text. An
   earlier version matched the reader's name with a regex, which a comment
   naming the function satisfied on its own: deleting the real call from
   ``scripts/test.sh`` left the comment beside it, and the build stayed green
   with no floor enforced anywhere. So the reader must now appear as the word
   that starts a command, in a code path the file actually reaches -- not in a
   comment, not inside a string, and not in a function nothing calls. The
   reader names are derived from the library instead of written here, so
   renaming one cannot leave this check looking for a name that no longer
   exists.

   The reading itself is ``scripts/lib/shellread.py``'s, not this file's. It
   used to be this file's, and the copy had two faults that both reported an
   unenforced floor as enforced: `if tool_floor_check nvim; then` read as a
   call to `if`, and a definition whose opening brace sat on the next line was
   not a definition at all, so an uncalled function's body counted as
   load-time code. That module carries the explanation; the point here is that
   ``validate-plan-network.py`` had grown its own variant of the same reader
   with its own version of the first fault, which is why there is now one.
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

A pin is read the way mise reads it, which is the part that is easy to get
wrong in both directions. A mise key may be backend-qualified, and a pin is a
*prefix* rather than an exact version: `python = "3"` provisions the newest
3.x, so it satisfies a 3.11 floor, while `python = "3.10"` cannot. Neither
does this check skip what it does not understand -- an unreadable pin or an
unclassified backend fails the build, because a check that silently drops a
pin reports success for a floor nobody is enforcing.

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
from shellread import (  # noqa: E402
    UnreadableShell,
    commands,
    function_bodies,
    outside_functions,
)

FIELDS = ["tool", "min_version", "requirement", "consumers"]
VERSION = re.compile(r"^[0-9]+(\.[0-9]+)*$")
# The library whose functions resolve the registry. Which of its functions
# count as readers is derived from it (see `readers`), not listed here: a list
# here would be a second place to update on a rename, and the failure mode of
# forgetting is this check passing for a floor nothing enforces.
FLOOR_LIBRARY = pathlib.Path("common") / "lib" / "tool-floors.sh"
# The variable that names the registry file. A library function whose body
# mentions it resolves the registry; one that calls such a function does too.
MANIFEST_VARIABLE = "TOOL_FLOOR_MANIFEST"
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
# `backend:name`, which is how mise names a tool it does not install from its
# own core registry. This repository's own configuration already uses the form.
BACKEND_KEY = re.compile(r"^(?P<backend>[A-Za-z0-9_-]+):(?P<name>.+)$")
# Backends that install the tool itself, so the name after them is the tool
# this registry may hold a floor for: `github:neovim/neovim` is Neovim.
TOOL_BACKENDS = {"aqua", "asdf", "core", "github", "gitlab", "ubi", "vfox"}
# Backends that install a package from a language ecosystem. The name after
# them is a package, not a tool identity: the npm package `neovim` is Neovim's
# Node client library, on its own version line, and holding it to Neovim's
# floor would check the wrong artefact. These are skipped deliberately, which
# is why an unlisted backend is an error rather than a third silent case.
PACKAGE_BACKENDS = {"cargo", "dotnet", "gem", "go", "npm", "pip", "pipx", "spm"}
# A version pin, with mise's optional explicit `prefix:` marker. `latest` and
# the rest of mise's symbolic pins are handled separately.
PIN_VERSION = re.compile(r"^(?:prefix:)?(?P<version>[0-9]+(?:\.[0-9]+)*)$")
# A pin that names no version cannot drift below a floor.
UNVERSIONED = {"latest"}
# What `interpret_pin` returns for a pin it cannot read at all.
UNREADABLE = object()
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


# The floor library named no reader, or a consumer could not be read as shell:
# either way nothing about enforcement is known. `scripts/lib/shellread.py`
# raises the second, so the two are one exception rather than two that every
# caller would have to remember to catch separately.
UnreadableLibrary = UnreadableShell


class UnclassifiedBackend(Exception):
    """A mise backend this check has never been told how to read."""


def close_over(start: set[str], bodies: dict[str, str]) -> set[str]:
    """Everything reachable from `start` by calling the functions in `bodies`."""
    reached = set(start)
    pending = list(start)
    while pending:
        name = pending.pop()
        for called in commands(bodies.get(name, "")):
            if called not in reached:
                reached.add(called)
                pending.append(called)
    return reached


def readers(library: pathlib.Path) -> set[str]:
    """The library functions that resolve the registry, directly or not.

    Derived rather than declared: a function whose body names the manifest
    variable reads the registry, and so does one that calls such a function.
    `tool_version` is deliberately not among them -- asking a tool its version
    without comparing it to the floor enforces nothing.
    """
    if not library.is_file():
        raise UnreadableLibrary(f"{library} is missing")
    bodies = function_bodies(library.read_text(encoding="utf-8"))
    resolving = {
        name for name, body in bodies.items() if MANIFEST_VARIABLE in body
    }
    if not resolving:
        raise UnreadableLibrary(
            f"no function in {library.name} mentions {MANIFEST_VARIABLE}"
        )
    while True:
        grown = resolving | {
            name
            for name, body in bodies.items()
            if commands(body) & resolving
        }
        if grown == resolving:
            return resolving
        resolving = grown


def enforces(path: pathlib.Path, reader_names: set[str]) -> bool:
    """Whether this file runs a reader in a code path it actually reaches.

    Reachability is from what the file runs on load, out through the functions
    it defines. A reader called only from a function nothing calls enforces as
    little as a reader named only in a comment.
    """
    text = path.read_text(encoding="utf-8")
    bodies = function_bodies(text)
    return bool(close_over(commands(outside_functions(text)), bodies) & reader_names)


def satisfies(pin: str, minimum: str) -> bool:
    """Whether a mise pin can resolve to a version at or above the floor.

    A pin is a prefix, not an exact version: mise resolves `python = "3"` to
    the newest 3.x it can find. So the components the pin does not state are
    unbounded rather than zero, and a pin is refused only when no version it
    could resolve to reaches the floor. That is the opposite of the padding
    `version_at_least` in `common/lib/common.sh` does, which is right there:
    that compares a version a tool *reported*, where an absent component
    really is zero.
    """
    found = [int(part) for part in pin.split(".")]
    floor = [int(part) for part in minimum.split(".")]
    for stated, required in zip(found, floor):
        if stated != required:
            return stated > required
    return True


def pin_identity(key: str) -> str | None:
    """The tool a mise key names, or None when the key names a package.

    Raises `UnclassifiedBackend` for a backend this check has not been taught,
    because guessing either way is a wrong answer given silently.
    """
    match = BACKEND_KEY.match(key)
    if match is None:
        return key.lower()
    backend = match.group("backend").lower()
    if backend in PACKAGE_BACKENDS:
        return None
    if backend not in TOOL_BACKENDS:
        raise UnclassifiedBackend(backend)
    # `owner/repo`, and mise's trailing option syntax on the ubi backends.
    name = match.group("name").split("[")[0].rstrip("/")
    return name.rsplit("/", 1)[-1].lower()


def interpret_pin(pinned: object) -> str | None | object:
    """A pin's version prefix, None when it states no version, else UNREADABLE."""
    if isinstance(pinned, dict):
        if "version" not in pinned:
            return UNREADABLE
        pinned = pinned["version"]
    if not isinstance(pinned, str):
        return UNREADABLE
    if pinned.lower() in UNVERSIONED:
        return None
    match = PIN_VERSION.match(pinned)
    return match.group("version") if match else UNREADABLE


def pin_keys(tool: str, label: str) -> set[str]:
    """The names a mise configuration may pin this registry tool under.

    The registry's own two spellings of a tool -- the command name it keys on
    and the label the toolchain table gives it -- are the whole identity, so a
    backend-qualified key is resolved back to a name by `pin_identity` and
    matched here rather than by a second list of names kept in step by hand.
    """
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
    # The readers come from this repository's own library rather than from
    # --root, because which functions resolve the registry is a fact about the
    # library, not about the tree being checked. A tree with no library still
    # has its consumers classified against the real reader set.
    try:
        reader_names = readers(
            pathlib.Path(__file__).resolve().parents[1] / FLOOR_LIBRARY
        )
    except UnreadableLibrary as unreadable:
        fail(
            f"cannot tell which functions read the registry: {unreadable}. "
            f"Every consumer check depends on that, so this is a failure "
            f"rather than a pass"
        )
        return 1

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
            try:
                enforced = enforces(path, reader_names)
            except UnreadableLibrary as unreadable:
                fail(
                    f"{consumer} cannot be read as shell: {unreadable}. Until it "
                    f"parses, whether it enforces the {tool} floor is unknown, "
                    f"which is not the same as enforced"
                )
                errors += 1
                continue
            if not enforced:
                named = "/".join(sorted(reader_names))
                fail(
                    f"{consumer} is named as enforcing the {tool} floor but never reads "
                    f"it; call {named} instead of restating {minimum}. A mention in a "
                    f"comment, in a string, or in a function nothing calls does not "
                    f"count"
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

    identities = {tool: pin_keys(tool, names[tool]) for tool in floors}
    for path in tracked(root, MISE_CONFIG):
        config = path.relative_to(root).as_posix()
        with path.open("rb") as stream:
            pins = tomllib.load(stream).get("tools", {})
        for key, requested in pins.items():
            try:
                identity = pin_identity(key)
            except UnclassifiedBackend as unclassified:
                fail(
                    f"{config} pins {key} through the {unclassified} mise backend, "
                    f"which this check cannot classify; add it to TOOL_BACKENDS in "
                    f"{pathlib.Path(__file__).name} when it installs the tool "
                    f"itself, or to PACKAGE_BACKENDS when it installs a package"
                )
                errors += 1
                continue
            if identity is None:
                continue
            tool = next(
                (name for name, keys in identities.items() if identity in keys), None
            )
            if tool is None:
                continue
            minimum = floors[tool]
            for entry in requested if isinstance(requested, list) else [requested]:
                written = entry.get("version", entry) if isinstance(entry, dict) else entry
                interpreted = interpret_pin(entry)
                if interpreted is UNREADABLE:
                    fail(
                        f"{config} pins {key} {written!r}, which this check cannot read "
                        f"as a version; state a version or 'latest', or teach "
                        f"{pathlib.Path(__file__).name} the form. A pin it skips is a "
                        f"{tool} floor nothing enforces"
                    )
                    errors += 1
                    continue
                if interpreted is None or satisfies(interpreted, minimum):
                    continue
                fail(
                    f"{config} pins {key} {written}; {manifest.name} requires "
                    f"{tool} {minimum} or newer"
                )
                errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
