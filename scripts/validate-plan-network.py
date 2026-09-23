#!/usr/bin/env python3
"""Hold each execution-plan step's declared scripts to what it actually runs.

``plan_add``'s last field names the repository scripts a step runs, and
``preflight_plan_network`` derives its probe set from those: a source in
``config/network-sources.tsv`` is probed when the resolved plan contains a step
that runs one of the source's consumers. That makes the declaration
load-bearing, and a wrong one fails open -- the host is simply never probed,
and the run mutates before discovering it cannot download.

So the declaration is checked here rather than trusted. Two jobs:

1. **The declaration matches the step.** Every repository script a step's apply
   function can reach -- directly, through a helper it calls, or through the
   argument vector it hands ``plan_command_run`` -- must be declared, and
   nothing else may be.
2. **A source a planned script fetches is reachable.** A step's script may
   source a library that does the fetching, and the registry row would then
   name only the library. The preflight matches consumers against the step's
   own scripts, so such a row would never be probed. Every
   ``# network-source: <id>`` annotation a planned script can reach must
   therefore name a row whose consumers include that script.

   Reachability here is per function, not per file. Sourcing
   ``platforms/fedora/lib/fedora.sh`` does not fetch everything that library
   can fetch; only the functions the script actually calls do. Taking the file
   as the unit would make every Fedora step look as though it downloaded every
   Fedora source, and the preflight would probe hosts the run never touches.

Usage:
    scripts/validate-plan-network.py [--root DIR]
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402
from shell import (  # noqa: E402
    UnreadableShell,
    blank_text,
    commands,
    outside_functions,
    shell_functions,
)

FIELDS = [
    "id", "component", "owner", "kind", "url", "privilege", "tier",
    "requested", "resolved", "integrity", "cadence", "rollback", "consumers",
]
# The repository's top-level directories a script path can start in.
TOPLEVEL = ("common", "platforms", "scripts", "tests", "bin", "nvim-lazyvim")
SCRIPT = re.compile(
    r"(?:\$DOTFILES_ROOT/|\$repo_root/|(?<![\w/.-]))"
    r"(?P<path>(?:" + "|".join(TOPLEVEL) + r")/[A-Za-z0-9._/-]+\.(?:sh|py))"
)
# A function reached through the plan's own command-vector indirection, where
# the function name is an argument rather than the word starting a statement.
COMMAND_VECTOR = re.compile(
    r"plan_command_(?:run|note)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
# `source` or `.` in command position, in blanked text. The word it sources is
# read from the original line at the same column, because blanking empties the
# quoted path a source line is almost always written as.
SOURCE_COMMAND = re.compile(
    r"(?:^|[;&|({]|\b(?:then|do|else)\b)\s*(?:source|\.)[ \t]+(?=\S)"
)
# Variables that name the checkout itself wherever they are used: the
# installers export DOTFILES_ROOT, and every script that sets repo_root sets it
# to the checkout.
ROOT_VARIABLES = {"DOTFILES_ROOT", "repo_root"}
# What names the script being read: `$(dirname "${BASH_SOURCE[0]}")` is its
# directory.
SELF_VARIABLES = {"BASH_SOURCE", "BASH_SOURCE[0]", "0"}
# How deep one variable may be defined through another before the chain is
# treated as unreadable.
EXPANSION_DEPTH = 8
ANNOTATION = re.compile(r"#\s*network-source:\s*(?P<ids>[A-Za-z0-9,._-]+)")


def fail(message: str) -> None:
    print(f"plan network: {message}", file=sys.stderr)


def tokenize(line: str) -> list[str]:
    """Split a shell command line, keeping quotes and `$(...)` whole."""
    tokens: list[str] = []
    current = ""
    quote = None
    index = 0
    while index < len(line):
        character = line[index]
        if quote:
            current += character
            if character == quote:
                quote = None
        elif character in "'\"":
            current += character
            quote = character
        elif line[index : index + 2] == "$(":
            depth = 1
            current += "$("
            index += 2
            while index < len(line) and depth:
                if line[index] == "(":
                    depth += 1
                elif line[index] == ")":
                    depth -= 1
                current += line[index]
                index += 1
            continue
        elif character.isspace():
            if current:
                tokens.append(current)
                current = ""
        else:
            current += character
        index += 1
    if current:
        tokens.append(current)
    return tokens


def functions(paths: list[pathlib.Path]) -> dict[str, str]:
    """Every function body in these files, by name, first definition winning."""
    found: dict[str, str] = {}
    for path in paths:
        if not path.is_file():
            continue
        try:
            bodies = shell_functions(path.read_text(encoding="utf-8"))
        except UnreadableShell as unreadable:
            raise UnreadableShell(f"{path}: {unreadable}") from unreadable
        for name, body in bodies.items():
            found.setdefault(name, body)
    return found


def reachable_scripts(
    name: str, bodies: dict[str, str], seen: set[str] | None = None
) -> set[str]:
    """Every repository script running this function can reach."""
    seen = seen if seen is not None else set()
    if name in seen or name not in bodies:
        return set()
    seen.add(name)
    body = bodies[name]
    scripts = {match.group("path") for match in SCRIPT.finditer(body)}
    for match in COMMAND_VECTOR.finditer(body):
        scripts |= reachable_scripts(match.group("name"), bodies, seen)
    for called in commands(body):
        scripts |= reachable_scripts(called, bodies, seen)
    return scripts


def reachable_sources(
    name: str, bodies: dict[str, str], seen: set[str] | None = None
) -> set[str]:
    """Every annotated network source running this function can reach."""
    seen = seen if seen is not None else set()
    if name in seen or name not in bodies:
        return set()
    seen.add(name)
    return sources_in(bodies[name], bodies, seen)


def sources_in(text: str, bodies: dict[str, str], seen: set[str]) -> set[str]:
    """The annotations in this text, plus those of every function it calls."""
    found: set[str] = set()
    for match in ANNOTATION.finditer(text):
        found |= {name for name in match.group("ids").split(",") if name}
    for match in COMMAND_VECTOR.finditer(text):
        found |= reachable_sources(match.group("name"), bodies, seen)
    for called in commands(text):
        found |= reachable_sources(called, bodies, seen)
    return found


def script_sources(root: pathlib.Path, script: str) -> tuple[set[str], list[str]]:
    """Every network source this repository script can reach when it runs.

    Returned with the source lines the closure could not follow, which the
    caller must fail on: a library the closure cannot see is a library whose
    annotations it cannot see either.
    """
    start = root / script
    if not start.is_file():
        return set(), []
    found, unresolved = sourced_closure(root, start)
    bodies = functions(sorted(found))
    return (
        sources_in(outside_functions(start.read_text(encoding="utf-8")), bodies, set()),
        unresolved,
    )


def assignments(code: list[str], name: str) -> list[str]:
    """The values `name` is assigned in these code lines, as written."""
    pattern = re.compile(
        r"^\s*(?:(?:local|readonly|declare(?:\s+-[A-Za-z]+)*)\s+)?"
        + re.escape(name)
        + r"=(?P<value>\S.*)$"
    )
    values = []
    for line in code:
        match = pattern.match(line)
        if match is not None:
            tokens = tokenize(match.group("value"))
            values.append(tokens[0] if tokens else "")
    return values


def expand(
    word: str, path: pathlib.Path, root: pathlib.Path, code: list[str], depth: int = 0
) -> str | None:
    """The path a sourced word names, or None when it cannot be known statically.

    Only what a reader can know for certain is expanded: the script's own
    location, the checkout's root, `$(dirname X)`, `$(cd X && pwd)`, and a
    variable assigned exactly once in the same file to something that expands
    in turn. Anything else -- a variable assigned twice, a positional
    parameter, any other command -- is None, and the caller reports it.
    """
    if depth > EXPANSION_DEPTH:
        return None
    result = ""
    index = 0
    while index < len(word):
        character = word[index]
        if word.startswith("$(", index):
            level, end = 0, index + 1
            while end < len(word):
                if word[end] == "(":
                    level += 1
                elif word[end] == ")":
                    level -= 1
                    if level == 0:
                        break
                end += 1
            if end >= len(word):
                return None
            value = substitution(word[index + 2 : end], path, root, code, depth + 1)
            if value is None:
                return None
            result += value
            index = end + 1
            continue
        if character == "$":
            braced = re.match(r"\{(?P<name>[^}]+)\}", word[index + 1 :])
            bare = re.match(r"(?P<name>[A-Za-z_][A-Za-z0-9_]*|[0-9])", word[index + 1 :])
            match = braced or bare
            if match is None:
                return None
            value = variable(match.group("name"), path, root, code, depth + 1)
            if value is None:
                return None
            result += value
            index += 1 + match.end()
            continue
        if character == "'":
            end = word.find("'", index + 1)
            if end == -1:
                return None
            result += word[index + 1 : end]
            index = end + 1
            continue
        if character == "\\" and index + 1 < len(word):
            result += word[index + 1]
            index += 2
            continue
        if character == "`":
            return None
        if character != '"':
            result += character
        index += 1
    return result


def variable(
    name: str, path: pathlib.Path, root: pathlib.Path, code: list[str], depth: int
) -> str | None:
    if name in SELF_VARIABLES:
        return str(path)
    if name in ROOT_VARIABLES:
        return str(root)
    values = assignments(code, name)
    if len(values) != 1:
        return None
    return expand(values[0], path, root, code, depth)


def substitution(
    inner: str, path: pathlib.Path, root: pathlib.Path, code: list[str], depth: int
) -> str | None:
    """`dirname X` and `cd X && pwd`, the two ways a script finds its directory."""
    try:
        tokens = shlex.split(inner)
    except ValueError:
        return None
    options = {"--", "-P", "-L"}
    if tokens and tokens[0] == "dirname":
        operands = [token for token in tokens[1:] if token != "--"]
        if len(operands) != 1:
            return None
        value = expand(operands[0], path, root, code, depth)
        return None if value is None else os.path.dirname(value)
    if len(tokens) >= 4 and tokens[0] == "cd":
        split = tokens.index("&&") if "&&" in tokens else -1
        operands = [token for token in tokens[1:split] if token not in options]
        rest = [token for token in tokens[split + 1 :] if token not in options]
        if split == -1 or len(operands) != 1 or rest != ["pwd"]:
            return None
        value = expand(operands[0], path, root, code, depth)
        return None if value is None else os.path.normpath(value)
    return None


def sourced_closure(
    root: pathlib.Path, start: pathlib.Path
) -> tuple[set[pathlib.Path], list[str]]:
    """A script and every repository file it sources, transitively.

    Returned with a message for each source line that could not be followed.
    Skipping one is not an option: `source "$script_dir/../lib/fedora.sh"` is
    the same line as the `$(dirname ...)` spelling after the most ordinary
    refactor there is, and dropping it took seven libraries, `fetch.sh` among
    them, out of the preflight's view with lint still green.
    """
    found: set[pathlib.Path] = set()
    unresolved: list[str] = []
    pending = [start]
    while pending:
        path = pending.pop()
        if path in found or not path.is_file():
            continue
        found.add(path)
        text = path.read_text(encoding="utf-8")
        page = path.relative_to(root).as_posix() if root in path.parents else str(path)
        try:
            blanked = blank_text(text).split("\n")
        except UnreadableShell as unreadable:
            unresolved.append(f"{page}: {unreadable}")
            continue
        lines = text.splitlines()
        code = [line[: len(clean)] for line, clean in zip(lines, blanked)]
        for number, (line, clean) in enumerate(zip(lines, blanked), 1):
            for match in SOURCE_COMMAND.finditer(clean):
                tokens = tokenize(line[match.end() :])
                word = tokens[0] if tokens else ""
                candidate = expand(word, path, root, code)
                if candidate is None:
                    unresolved.append(
                        f"{page}:{number}: cannot tell which file `source {word}` "
                        f"reads, so what it can fetch is unknown, which is not the "
                        f"same as nothing; spell it with $(dirname \"${{BASH_SOURCE[0]}}\"), "
                        f"$DOTFILES_ROOT, or a variable assigned once from one of them"
                    )
                    continue
                bases = (
                    [pathlib.Path("/")]
                    if candidate.startswith("/")
                    else [root, path.parent, root / "common" / "lib"]
                )
                for base in bases:
                    resolved = (base / candidate).resolve()
                    if resolved.is_file() and root in resolved.parents:
                        pending.append(resolved)
                        break
                else:
                    unresolved.append(
                        f"{page}:{number}: `source {word}` names {candidate}, which "
                        f"is not a file in this checkout"
                    )
    return found, unresolved


def plan_steps(
    install: pathlib.Path, page: str
) -> tuple[list[tuple[int, str, str, set[str]]], int]:
    """Each `plan_add` line: its line number, id, apply function and declaration.

    Returned with the number of lines that could not be read. A `plan_add` line
    the tokeniser cannot split into the command and its seven arguments is a
    build error, not a line to skip: dropping it takes the step out of the
    check in both directions, so an undeclared network step would pass and the
    preflight would never probe the host it downloads from. Shell the tokeniser
    does not understand -- a trailing comment, say -- has to be reported and
    fixed, here or in the tokeniser.
    """
    steps = []
    errors = 0
    for number, line in enumerate(install.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        start = stripped.find("plan_add ")
        if start == -1:
            continue
        tokens = tokenize(stripped[start:])
        if len(tokens) != 8:
            fail(
                f"{page}:{number}: cannot read this plan_add line as a command "
                f"with seven arguments (read {len(tokens) - 1}); every step has "
                f"to be checked, so an unreadable one is a build error"
            )
            errors += 1
            continue
        declared = tokens[7].strip("'\"").split()
        steps.append((number, tokens[1].strip("'\""), tokens[5], set(declared)))
    return steps, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    manifest = pathlib.Path(
        os.environ.get("NETWORK_SOURCE_MANIFEST", root / "config" / "network-sources.tsv")
    )

    try:
        rows = read_tsv(manifest, FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1
    consumers = {
        row["id"]: {name for name in row["consumers"].split(",") if name}
        for row in rows
    }

    installs = sorted((root / "platforms").glob("*/install.sh"))
    if not installs:
        fail(f"no platform installers under {root / 'platforms'}")
        return 1

    errors = 0
    reported: set[str] = set()
    for install in installs:
        platform = install.parent.name
        try:
            bodies = functions(
                [install]
                + sorted((install.parent / "lib").glob("*.sh"))
                + sorted((root / "common" / "lib").glob("*.sh"))
            )
        except UnreadableShell as unreadable:
            fail(
                f"{platform}: {unreadable}. Until it parses, which scripts a step "
                f"runs is unknown, which is not the same as none"
            )
            errors += 1
            continue
        page = install.relative_to(root).as_posix()
        steps, unreadable = plan_steps(install, page)
        errors += unreadable
        if not steps:
            fail(f"{platform}: no plan_add step declares its scripts")
            errors += 1
            continue

        for number, step, apply_function, declared in steps:
            reached = reachable_scripts(apply_function, bodies)
            missing = sorted(reached - declared)
            if missing:
                fail(
                    f"{page}:{number}: step {step} runs {', '.join(missing)} but does "
                    f"not declare it; the preflight cannot probe what that script "
                    f"downloads from"
                )
                errors += 1
            extra = sorted(declared - reached)
            if extra:
                fail(
                    f"{page}:{number}: step {step} declares {', '.join(extra)}, which "
                    f"{apply_function} does not run; a stale declaration probes a host "
                    f"this step does not use"
                )
                errors += 1

            for script in sorted(declared):
                try:
                    sources, unresolved = script_sources(root, script)
                except UnreadableShell as unreadable:
                    sources, unresolved = set(), [
                        f"{script}: {unreadable}. Until it parses, what it can "
                        f"fetch is unknown, which is not the same as nothing"
                    ]
                for message in unresolved:
                    if message in reported:
                        continue
                    reported.add(message)
                    fail(message)
                    errors += 1
                for source in sorted(sources):
                    if source not in consumers or script in consumers[source]:
                        continue
                    message = (
                        f"{script} can fetch {source}, and {platform}'s {step} step "
                        f"runs it, but that source's consumers do not name {script}; "
                        f"add it so the preflight probes the host"
                    )
                    if message in reported:
                        continue
                    reported.add(message)
                    fail(message)
                    errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
