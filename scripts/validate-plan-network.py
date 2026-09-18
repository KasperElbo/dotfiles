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
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402

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
DEFINITION = re.compile(r"^(?P<name>[A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{?")
# A function reached through the plan's own command-vector indirection, where
# the function name is an argument rather than the word starting a statement.
COMMAND_VECTOR = re.compile(
    r"plan_command_(?:run|note)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
# A function called as a command: the first word of a statement.
CALL = re.compile(
    r"(?:^|[;&|]|\|\||&&|\$\(|\bthen\b|\belse\b|\bdo\b)\s*"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b"
)
SOURCED = re.compile(
    r"^\s*(?:source|\.)\s+\"?(?:\$DOTFILES_ROOT/|\$repo_root/|\$\(dirname[^)]*\)/)?"
    r"(?P<path>[A-Za-z0-9._/${}-]+\.sh)"
)
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
        lines = path.read_text(encoding="utf-8").splitlines()
        index = 0
        while index < len(lines):
            match = DEFINITION.match(lines[index])
            if match is None:
                index += 1
                continue
            body = [lines[index]]
            if "}" in lines[index][match.end() :] or lines[index].rstrip().endswith("}"):
                found.setdefault(match.group("name"), "\n".join(body))
                index += 1
                continue
            index += 1
            while index < len(lines) and not lines[index].startswith("}"):
                body.append(lines[index])
                index += 1
            found.setdefault(match.group("name"), "\n".join(body))
            index += 1
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
    for line in body.splitlines():
        for match in CALL.finditer(line):
            scripts |= reachable_scripts(match.group("name"), bodies, seen)
    return scripts


def strip_functions(text: str) -> str:
    """The file's top-level code, with its function bodies removed."""
    lines = text.splitlines()
    kept: list[str] = []
    index = 0
    while index < len(lines):
        match = DEFINITION.match(lines[index])
        if match is None:
            kept.append(lines[index])
            index += 1
            continue
        if "}" in lines[index][match.end() :] or lines[index].rstrip().endswith("}"):
            index += 1
            continue
        index += 1
        while index < len(lines) and not lines[index].startswith("}"):
            index += 1
        index += 1
    return "\n".join(kept)


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
    for line in text.splitlines():
        for match in CALL.finditer(line):
            found |= reachable_sources(match.group("name"), bodies, seen)
    return found


def script_sources(root: pathlib.Path, script: str) -> set[str]:
    """Every network source this repository script can reach when it runs."""
    start = root / script
    if not start.is_file():
        return set()
    closure = sorted(sourced_closure(root, start))
    bodies = functions(closure)
    return sources_in(strip_functions(start.read_text(encoding="utf-8")), bodies, set())


def sourced_closure(root: pathlib.Path, start: pathlib.Path) -> set[pathlib.Path]:
    """A script and every repository file it sources, transitively."""
    found: set[pathlib.Path] = set()
    pending = [start]
    while pending:
        path = pending.pop()
        if path in found or not path.is_file():
            continue
        found.add(path)
        for line in path.read_text(encoding="utf-8").splitlines():
            match = SOURCED.match(line)
            if match is None:
                continue
            candidate = match.group("path")
            if "$" in candidate:
                continue
            for base in (root, path.parent, root / "common" / "lib"):
                resolved = (base / candidate).resolve()
                if resolved.is_file() and root in resolved.parents:
                    pending.append(resolved)
                    break
    return found


def plan_steps(install: pathlib.Path) -> list[tuple[int, str, str, set[str]]]:
    """Each `plan_add` line: its line number, id, apply function and declaration."""
    steps = []
    for number, line in enumerate(install.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        start = stripped.find("plan_add ")
        if start == -1:
            continue
        tokens = tokenize(stripped[start:])
        if len(tokens) != 9:
            continue
        declared = tokens[8].strip("'\"").split()
        steps.append((number, tokens[1].strip("'\""), tokens[5], set(declared)))
    return steps


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
        bodies = functions(
            [install]
            + sorted((install.parent / "lib").glob("*.sh"))
            + sorted((root / "common" / "lib").glob("*.sh"))
        )
        steps = plan_steps(install)
        if not steps:
            fail(f"{platform}: no plan_add step declares its scripts")
            errors += 1
            continue

        for number, step, apply_function, declared in steps:
            reached = reachable_scripts(apply_function, bodies)
            page = install.relative_to(root).as_posix()
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
                for source in sorted(script_sources(root, script)):
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
