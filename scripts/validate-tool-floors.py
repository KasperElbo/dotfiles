#!/usr/bin/env python3
"""Validate the dependency version-floor registry and its enforcement.

``config/tool-floors.tsv`` is the one place a documented minimum version is
stated for a tool this repository's toolchain preflights; ``docs/testing.md``
names the one floor deliberately kept outside it. Before it existed, three documentation pages stated two different
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

   The shell is read by ``scripts/lib/shell.py``, which every validator that
   reads shell shares. This check used to carry its own copy, and that copy
   decided a definition by where its brace sat: with the brace on the line
   below, an uncalled function read as load-time code and its floor check
   counted, while the equivalent ``if ! tool_floor_check nvim; then die; fi``
   was refused with a message saying the call was in a comment or a string.
   How a definition is spelled says nothing about whether its body runs, so
   the reader treats the three spellings alike.

2. **The documentation disagrees with the table.** Every page that states a
   minimum for a tool the registry knows -- in ``>= 0.12``, ``0.12+``,
   ``0.12 or newer`` or ``at least 0.12`` form, wherever it is written -- must
   state the registry's floor, and ``docs/testing.md`` must state every floor,
   so a new floor cannot be added without documenting it and a documented one
   cannot drift on a page nobody remembered to update. A minimum is attributed
   to the tool its sentence names, else to the tool its section heading names;
   one attributable to neither is reported, never skipped, unless the subject
   written directly before it is something the registry deliberately does not
   track (``UNTRACKED_SUBJECTS``).
3. **A floor enforced before any reader can run drifts.** Bash is the
   interpreter every reader runs under, so its floor is decided while the
   shell may still be Apple's 3.2, before ``common/lib/tool-floors.sh`` can be
   sourced. Its enforcement sites are the ``BASH_VERSINFO`` comparisons
   themselves, four of them, plus the constants and messages that restate the
   number. Each comparison is read for the version it actually admits -- it is
   evaluated, not pattern-matched, so ``> 4`` where ``>= 4`` was meant is a
   4.5 floor and is refused -- and every restatement must equal the row. A
   non-test shell file that compares ``BASH_VERSINFO`` without being one of
   the row's consumers is refused too, so a fifth site cannot be added
   outside the registry (#539, V5-03).
4. **A pinned version falls below its own floor.** The mise configurations
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
from manifests import ManifestSchemaError, read_tsv, shell_files  # noqa: E402
from shell import (  # noqa: E402
    UnreadableShell,
    close_over,
    code_text,
    commands,
    outside_functions,
    shell_functions,
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
# Minimums the documentation states for something that is not a tool this
# registry tracks, and why each is outside it. Such a floor is recognised only
# when the subject is written directly before the number -- `Bash 4.4 or
# newer`, `a kernel of at least 7.1`, `macOS 14.0+` -- so a sentence that
# merely mentions macOS before stating Neovim's floor is still read as
# Neovim's. A floor that belongs to neither this table nor the registry, and
# names no tool at all, is reported rather than skipped.
UNTRACKED_SUBJECTS = {
    "kernel": "the distribution's, enforced by "
    "platforms/fedora/scripts/install-asus-hardware.sh (docs/testing.md)",
    "macos": "the operating system a third-party application requires, "
    "which this repository cannot raise",
}
UNTRACKED_FLOOR = re.compile(
    r"(?<![\w.-])(?:" + "|".join(UNTRACKED_SUBJECTS) + r")\s+(?:of\s+)?$",
    re.IGNORECASE,
)
# A compound name written directly before a floor -- `nvim-treesitter 0.25+`,
# `lazy.nvim 11.0+` -- names the thing the floor is for, and by `MENTION`'s own
# rule it is not a registry tool even when a tool's name is part of it.
COMPOUND_SUBJECT = re.compile(r"(?<![\w.-])`?[A-Za-z0-9_]+(?:[.-][A-Za-z0-9_]+)+`?\s+$")
# A Markdown heading, and a fence opening or closing a code block; a `#` line
# inside a fence is a shell comment, not a heading.
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")
FENCE = re.compile(r"^\s{0,3}(?:```|~~~)")
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
# The tool whose floor is enforced by comparing BASH_VERSINFO rather than by a
# reader: the reader library needs the Bash this floor is about.
VERSINFO_TOOL = "bash"
# One `(( ... ))` arithmetic test that reads BASH_VERSINFO, on one line.
VERSINFO_TEST = re.compile(r"\(\((?P<expression>[^\n]*BASH_VERSINFO[^\n]*)\)\)")
# The only tokens such a test may contain, so evaluating it is evaluating
# arithmetic over two version components and nothing else.
VERSINFO_TOKEN = re.compile(
    r"\s*(?:(?P<field>BASH_VERSINFO\[(?P<index>[01])\])|(?P<number>[0-9]+)"
    r"|(?P<operator>>=|<=|==|!=|>|<|\|\||&&|!|\(|\)))"
)
# A restated Bash floor: `Bash 4.4 or newer`, `Bash 4.4+`, in a message.
VERSINFO_STATED = re.compile(r"\bBash\s+(?P<version>[0-9]+\.[0-9]+)(?=\s+or\s+newer|\+)")
# A restated Bash floor held in a variable: MODERN_BASH_MINIMUM="4.4".
VERSINFO_ASSIGNED = re.compile(
    r"^\s*(?:export\s+|readonly\s+|local\s+)?(?P<name>\w*(?:bash\w*min|min\w*bash)\w*)="
    r"[\"']?(?P<version>[0-9]+(?:\.[0-9]+)+)[\"']?\s*$",
    re.IGNORECASE,
)
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


class UnclassifiedBackend(Exception):
    """A mise backend this check has never been told how to read."""


def readers(library: pathlib.Path) -> set[str]:
    """The library functions that resolve the registry, directly or not.

    Derived rather than declared: a function whose body names the manifest
    variable reads the registry, and so does one that calls such a function.
    `tool_version` is deliberately not among them -- asking a tool its version
    without comparing it to the floor enforces nothing.
    """
    if not library.is_file():
        raise UnreadableShell(f"{library} is missing")
    bodies = shell_functions(library.read_text(encoding="utf-8"))
    resolving = {
        name for name, body in bodies.items() if MANIFEST_VARIABLE in body
    }
    if not resolving:
        raise UnreadableShell(
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
    bodies = shell_functions(text)
    return bool(close_over(commands(outside_functions(text)), bodies) & reader_names)


def admitted_floor(expression: str) -> str:
    """The Bash version a BASH_VERSINFO test admits from, as `major.minor`.

    The test is evaluated over every version it could be asked about, rather
    than matched against the spelling this repository happens to use, so the
    two polarities -- `> 4 || (== 4 && >= 4)` admitting, `< 4 || (== 4 && < 4)`
    refusing -- and any rewording of either are read alike. A test that is not
    a floor at all (it admits an older version and refuses a newer one) is
    unreadable rather than guessed at.
    """
    python: list[str] = []
    position = 0
    while position < len(expression):
        if not expression[position:].strip():
            break
        token = VERSINFO_TOKEN.match(expression, position)
        if token is None or token.end() == position:
            raise UnreadableShell(
                f"the BASH_VERSINFO test {expression.strip()!r} uses "
                f"{expression[position:].strip()[:12]!r}, which this check cannot evaluate"
            )
        position = token.end()
        if token.group("field"):
            python.append(f"version[{token.group('index')}]")
        elif token.group("number"):
            python.append(token.group("number"))
        else:
            python.append({"||": " or ", "&&": " and ", "!": " not "}.get(
                token.group("operator"), token.group("operator")))
    try:
        test = compile("".join(python), "<BASH_VERSINFO>", "eval")
    except SyntaxError as error:
        raise UnreadableShell(
            f"the BASH_VERSINFO test {expression.strip()!r} does not parse: {error.msg}"
        ) from None
    grid = [(major, minor) for major in range(10) for minor in range(40)]
    outcome = {
        version: bool(eval(test, {"__builtins__": {}}, {"version": version}))  # noqa: S307
        for version in grid
    }
    # An admitting test is true for the newest version; a refusing one false.
    admits = outcome if outcome[grid[-1]] else {v: not r for v, r in outcome.items()}
    admitted = [version for version in grid if admits[version]]
    if not admitted or admits[grid[0]]:
        raise UnreadableShell(
            f"the BASH_VERSINFO test {expression.strip()!r} is not a minimum version"
        )
    floor = admitted[0]
    if any(admits[version] != (version >= floor) for version in grid):
        raise UnreadableShell(
            f"the BASH_VERSINFO test {expression.strip()!r} admits versions out of order"
        )
    return f"{floor[0]}.{floor[1]}"


def versinfo_sites(
    path: pathlib.Path, strict: bool = True
) -> tuple[list[tuple[int, str]], list[tuple[int, str, str]]]:
    """The file's BASH_VERSINFO tests, and every other statement of the floor.

    Read as code with its comments dropped: a comparison in a comment enforces
    nothing, and a message or a constant in a string still tells the user a
    number. Returns (line, admitted floor) for each test, and (line, what,
    version) for each restatement.

    In a consumer (``strict``), any other read of BASH_VERSINFO is unreadable:
    a floor spelled some other way would be one this check silently skipped.
    Elsewhere a plain read -- printing the version -- is not a floor at all.
    """
    text = code_text(path.read_text(encoding="utf-8"))
    tests: list[tuple[int, str]] = []
    stated: list[tuple[int, str, str]] = []
    for number, line in enumerate(text.splitlines(), 1):
        found = list(VERSINFO_TEST.finditer(line))
        if strict and "BASH_VERSINFO" in line and not found:
            raise UnreadableShell(
                f"line {number} reads BASH_VERSINFO outside a (( )) test this check can evaluate"
            )
        for match in found:
            tests.append((number, admitted_floor(match.group("expression"))))
        for match in VERSINFO_STATED.finditer(line):
            stated.append((number, "a message", match.group("version")))
        assigned = VERSINFO_ASSIGNED.match(line)
        if assigned:
            stated.append((number, assigned.group("name"), assigned.group("version")))
    return tests, stated


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


def untracked(raw: str, column: int) -> bool:
    """Whether the floor at `column` is written directly after an untracked subject.

    `at least` belongs to the floor, so `a kernel of at least 7.1` reads the
    subject from before `at least`, not from before the number.
    """
    before = raw[:column]
    before = re.sub(r"(?:at least|>=)\s*$", "", before, flags=re.IGNORECASE)
    return (
        UNTRACKED_FLOOR.search(before) is not None
        or COMPOUND_SUBJECT.search(before) is not None
    )


def mentioned_tools(raw: str, names: dict[str, str]) -> list[tuple[int, str]]:
    """Each registry tool this line names, with the column it is named at."""
    lowered = raw.lower()
    found = []
    for tool, label in names.items():
        for spelling in {tool.lower(), label.lower()}:
            for match in re.finditer(MENTION % re.escape(spelling), lowered):
                found.append((match.start(), tool))
    return sorted(found)


def attributed_floors(
    block: list[tuple[int, str]], names: dict[str, str], heading: str | None = None
) -> tuple[list[tuple[int, str | None, str]], bool]:
    """Each minimum the block states, paired with the tool it is stated for.

    A minimum belongs to the nearest tool name or label written before it in
    the same paragraph, so `Neovim 0.12+ and Python 3.11+` states one floor for
    each of the two tools rather than both numbers for both tools. Failing
    that, it belongs to the tool the section's heading names: `## Neovim`
    followed by "This toolchain requires 0.9 or newer." states Neovim's floor
    as plainly as a sentence that names it, and was the shape that went
    unchecked. A floor written directly after an untracked subject (see
    `UNTRACKED_SUBJECTS`) or after a compound name such as a plugin's is left
    out, because the subject it belongs to is written right there.

    The owner is ``None`` when neither the paragraph before the floor nor the
    heading names a registry tool; the second return value says whether the
    paragraph names one anywhere, so the caller can tell "named after the
    floor" from "named nowhere". Both are reported.
    """
    mentions: list[tuple[tuple[int, int], str]] = []
    floors: list[tuple[tuple[int, int], str]] = []
    for number, raw in block:
        for column, tool in mentioned_tools(raw, names):
            mentions.append(((number, column), tool))
        for column, version in stated_floors(raw):
            if not untracked(raw, column):
                floors.append(((number, column), version))
    mentions.sort()
    attributed = []
    for position, version in sorted(floors):
        owner = heading
        for start, tool in mentions:
            if start >= position:
                break
            owner = tool
        attributed.append((position[0], owner, version))
    return attributed, bool(mentions)


def sections(lines: list[str], names: dict[str, str]):
    """Each block of the page with the registry tool its heading names, if any."""
    heading: str | None = None
    fenced = False
    for block in blocks(lines):
        first = block[0][1]
        if not fenced and HEADING.match(first):
            named = mentioned_tools(first, names)
            heading = named[-1][1] if named else None
        for _, raw in block:
            if FENCE.match(raw):
                fenced = not fenced
        yield block, heading


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
    except UnreadableShell as unreadable:
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
                if tool == VERSINFO_TOOL:
                    tests, stated = versinfo_sites(path)
                    enforced = enforced or bool(tests)
                    for number, admitted in tests:
                        if admitted != minimum:
                            fail(
                                f"{consumer}:{number} compares BASH_VERSINFO so that it "
                                f"admits Bash {admitted}; {manifest.name} says {minimum}"
                            )
                            errors += 1
                    for number, what, version in stated:
                        if version != minimum:
                            fail(
                                f"{consumer}:{number} states Bash {version} as the "
                                f"minimum in {what}; {manifest.name} says {minimum}"
                            )
                            errors += 1
            except UnreadableShell as unreadable:
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

    # The other direction for the Bash floor: a comparison nobody registered is
    # a fifth statement of the number that nothing holds to the row.
    if VERSINFO_TOOL in floors:
        registered = {
            name.strip()
            for row in rows
            if (row["tool"] or "").strip() == VERSINFO_TOOL
            for name in row["consumers"].split(",")
        }
        for name in shell_files(root):
            if name.startswith("tests/") or name in registered:
                continue
            try:
                tests, _ = versinfo_sites(root / name, strict=False)
            except UnreadableShell as unreadable:
                fail(f"{name} cannot be read for a Bash floor: {unreadable}")
                errors += 1
                continue
            if tests:
                fail(
                    f"{name}:{tests[0][0]} compares BASH_VERSINFO but is not a consumer "
                    f"of the {VERSINFO_TOOL} row in {manifest.name}; add it there so "
                    f"its floor is checked"
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
        for block, heading in sections(lines, names):
            attributed, names_a_tool = attributed_floors(block, names, heading)
            for number, tool, stated in attributed:
                if tool is None and names_a_tool:
                    fail(
                        f"{page}:{number} states a {stated} minimum before naming the "
                        f"tool it belongs to; name the tool before its floor so the "
                        f"registry can check it"
                    )
                    errors += 1
                    continue
                if tool is None:
                    # Skipping this is how a floor for a registry tool went
                    # unchecked whenever its name sat in a heading or a table
                    # row rather than in the sentence itself.
                    untracked_names = ", ".join(sorted(UNTRACKED_SUBJECTS))
                    fail(
                        f"{page}:{number} states a {stated} minimum without naming "
                        f"the tool it is for, so no registry floor can be checked "
                        f"against it; name the tool in the sentence or its section "
                        f"heading, or, for a floor the registry does not track, "
                        f"write the subject directly before it ({untracked_names})"
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
