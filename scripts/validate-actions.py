#!/usr/bin/env python3
"""Validate the canonical registry of repository-defined user actions.

`config/actions.tsv` is the one authoritative inventory of what this
repository binds, aliases or installs as a user-invocable action. Prose
documentation and the printable cheat sheets are derived from it or checked
against it; neither is a second source of truth.

Four independent things are checked, because each catches a different way the
registry can quietly stop describing reality:

1. **Schema.** Columns, unique IDs, enumerated values, and the rule that
   `print=false` must carry a reason while `print=true` must name its sheets.
2. **Registry to implementation.** Every `origin=repository` action must still
   match its `source_pattern` in its `source` file. Renaming a binding without
   updating the registry fails here.
3. **Implementation to registry.** Custom actions are extracted back out of the
   tracked configuration — Sway with its own grammar, AeroSpace through a real
   TOML parser, Waybar through a real JSON parser, the shell through its alias
   and function syntax — and each one must be claimed by a registry row.
   Adding a binding without registering it fails here.
4. **Registry to cheat sheets.** A `print=true` action must appear on every
   sheet it names, and — the direction that keeps sheets honest — every
   `\\csrow` on a sheet must be claimed by a registry row that lists that sheet.
   This is what stops a shared block from advertising a Fedora-only option on
   macOS.

Usage:
    scripts/validate-actions.py [--root DIR]
"""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re
import sys
import tomllib

FIELDS = [
    "id", "platform", "profile", "component", "origin", "input", "binding",
    "action", "source", "source_pattern", "discoverability", "print",
    "sheets", "print_reason",
]
PLATFORMS = {"all", "fedora", "fedora-wsl", "macos", "parrot-ctf"}
ORIGINS = {"repository", "upstream"}
INPUTS = {"key", "mouse", "click", "command", "mode"}
DISCOVERABILITY = {"whichkey", "tool-help", "shell-help", "status-bar", "config-only", "documented"}
SHEETS = {"fedora-kde", "fedora-sway", "fedora-wsl", "macos", "parrot-ctf"}

CSROW = re.compile(r"\\csrow\{(?P<key>(?:[^{}]|\{[^{}]*\})*)\}")
INPUT_DIRECTIVE = re.compile(r"\\input\{(?P<name>[^}]+)\}")


def load(path: pathlib.Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE)
        if reader.fieldnames != FIELDS:
            raise SystemExit(f"action registry: unexpected columns: {reader.fieldnames}")
        return list(reader)


def check_schema(root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]) -> None:
    seen: set[str] = set()
    for line, row in enumerate(rows, 2):
        where = f"line {line} ({row['id']})"
        if row["id"] in seen:
            problems.append(f"{where}: duplicate action id")
        seen.add(row["id"])
        if not re.fullmatch(r"[a-z0-9]+(?:[.-][a-z0-9]+)*", row["id"]):
            problems.append(f"{where}: id must be lowercase dotted/dashed segments")
        for column, allowed in (
            ("platform", PLATFORMS), ("origin", ORIGINS), ("input", INPUTS),
            ("discoverability", DISCOVERABILITY),
        ):
            if row[column] not in allowed:
                problems.append(f"{where}: invalid {column} {row[column]!r}")
        if row["print"] not in {"true", "false"}:
            problems.append(f"{where}: print must be true or false")
            continue
        for column in ("binding", "action", "component", "profile"):
            if not row[column] or row[column] == "-":
                problems.append(f"{where}: {column} is required")
        if row["print"] == "true":
            if row["sheets"] == "-" or not row["sheets"]:
                problems.append(f"{where}: print=true must name the sheets it appears on")
            for sheet in row["sheets"].split(","):
                if sheet and sheet not in SHEETS:
                    problems.append(f"{where}: unknown cheat sheet {sheet!r}")
            if row["print_reason"] != "-":
                problems.append(f"{where}: print_reason belongs to print=false rows only")
        else:
            if row["sheets"] != "-":
                problems.append(f"{where}: print=false must not name sheets")
            if row["print_reason"] in {"", "-"}:
                problems.append(f"{where}: print=false requires a rationale")
        if row["origin"] == "repository":
            if row["source"] in {"", "-"}:
                problems.append(f"{where}: a repository-defined action must name its source")
            elif not (root / row["source"]).is_file():
                problems.append(f"{where}: source does not exist: {row['source']}")
            if row["source_pattern"] in {"", "-"}:
                problems.append(f"{where}: a repository-defined action must name a source pattern")


def check_registry_matches_implementation(
    root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]
) -> None:
    cache: dict[str, str] = {}
    for row in rows:
        if row["origin"] != "repository":
            continue
        source = row["source"]
        pattern = row["source_pattern"]
        if source in {"", "-"} or pattern in {"", "-"}:
            continue
        path = root / source
        if not path.is_file():
            continue
        if source not in cache:
            cache[source] = path.read_text(encoding="utf-8")
        try:
            expression = re.compile(pattern, re.MULTILINE)
        except re.error as error:
            problems.append(f"{row['id']}: invalid source pattern: {error}")
            continue
        if not expression.search(cache[source]):
            problems.append(
                f"{row['id']}: source_pattern no longer matches {source}; "
                "the action was renamed, moved or removed"
            )


def strip_jsonc(text: str) -> str:
    without_block = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"(?m)^\s*//.*$", "", without_block)


def implemented_actions(root: pathlib.Path) -> list[tuple[str, str]]:
    """Every custom action the tracked configuration actually defines.

    Returned as (source, evidence) pairs, where the evidence is the exact text
    a registry row has to claim.
    """
    found: list[tuple[str, str]] = []

    sway = root / "platforms/fedora/stow/sway/.config/sway/config"
    if sway.is_file():
        for line in sway.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("bindsym ") or stripped.startswith("bindgesture "):
                found.append((str(sway.relative_to(root)), stripped))

    aerospace = root / "platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml"
    if aerospace.is_file():
        data = tomllib.loads(aerospace.read_text(encoding="utf-8"))
        for mode, definition in (data.get("mode") or {}).items():
            for key, command in (definition.get("binding") or {}).items():
                rendered = command if isinstance(command, str) else " ".join(command)
                found.append((str(aerospace.relative_to(root)), f"{key} = '{rendered}'"))

    waybar = root / "platforms/fedora/stow/waybar/.config/waybar/config.jsonc"
    if waybar.is_file():
        data = json.loads(strip_jsonc(waybar.read_text(encoding="utf-8")))
        for module, definition in data.items():
            if not isinstance(definition, dict):
                continue
            for key, value in definition.items():
                if key.startswith("on-click") or key.startswith("on-scroll") or key == "exec":
                    found.append((str(waybar.relative_to(root)), f'"{key}": "{value}"'))

    for relative in (
        "zsh/.config/zsh/.zshrc",
        "platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh",
        "platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh",
    ):
        path = root / relative
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"(?m)^\s*alias\s+([A-Za-z0-9_-]+)=(.*)$", text):
            found.append((relative, f"alias {match.group(1)}={match.group(2).strip()}"))
        # Public shell functions only: a leading underscore marks an internal
        # helper, which is not a user action.
        for match in re.finditer(r"(?m)^([a-z][A-Za-z0-9_-]*)\(\)\s*\{", text):
            found.append((relative, f"{match.group(1)}() {{"))

    return found


def check_implementation_is_registered(
    root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]
) -> None:
    patterns: list[tuple[str, re.Pattern[str]]] = []
    for row in rows:
        if row["origin"] != "repository" or row["source_pattern"] in {"", "-"}:
            continue
        try:
            patterns.append((row["source"], re.compile(row["source_pattern"])))
        except re.error:
            continue

    for source, evidence in implemented_actions(root):
        if any(source == owner and expression.search(evidence) for owner, expression in patterns):
            continue
        problems.append(
            f"{source}: unregistered custom action: {evidence.strip()!r}; "
            "add it to config/actions.tsv"
        )


def expanded_sheet(root: pathlib.Path, sheet: str) -> str:
    directory = root / "docs" / "cheatsheets"
    path = directory / f"{sheet}.tex"
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8")
    for match in INPUT_DIRECTIVE.finditer(text):
        included = directory / f"{match.group('name')}.tex"
        if included.is_file():
            text += "\n" + included.read_text(encoding="utf-8")
    return text


def normalize(value: str) -> str:
    """Compare bindings without LaTeX escaping or spacing noise."""
    value = re.sub(r"\\texttt\{([^{}]*)\}", r"\1", value)
    value = re.sub(r"\\textbar\s*", "|", value)
    value = re.sub(r"\\textasciitilde\s*", "~", value)
    value = re.sub(r"\\[a-zA-Z]+", "", value)
    value = value.replace("\\", "")
    value = re.sub(r"[{}$]", "", value)
    return re.sub(r"\s+", "", value).lower()


def check_cheat_sheets(root: pathlib.Path, rows: list[dict[str, str]], problems: list[str]) -> None:
    sheets = {sheet: expanded_sheet(root, sheet) for sheet in sorted(SHEETS)}
    for sheet, text in sheets.items():
        if not text:
            problems.append(f"cheat sheet source is missing: docs/cheatsheets/{sheet}.tex")

    keys = {
        sheet: {normalize(match.group("key")) for match in CSROW.finditer(text)}
        for sheet, text in sheets.items()
    }
    claimed: dict[str, set[str]] = {sheet: set() for sheet in sheets}

    for row in rows:
        if row["print"] != "true":
            continue
        binding = normalize(row["binding"])
        for sheet in row["sheets"].split(","):
            if sheet not in sheets:
                continue
            if binding in keys[sheet]:
                claimed[sheet].add(binding)
            elif normalize(row["binding"]) in normalize(sheets[sheet]):
                # Prose rather than a table row: acceptable, still present.
                claimed[sheet].add(binding)
            else:
                problems.append(
                    f"{row['id']}: print=true names {sheet}, but the sheet does not "
                    f"document {row['binding']!r}"
                )

    for sheet, sheet_keys in keys.items():
        for key in sorted(sheet_keys - claimed[sheet]):
            problems.append(
                f"docs/cheatsheets/{sheet}.tex: printed action {key!r} is not in "
                "config/actions.tsv for this sheet"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    rows = load(root / "config" / "actions.tsv")
    problems: list[str] = []
    check_schema(root, rows, problems)
    check_registry_matches_implementation(root, rows, problems)
    check_implementation_is_registered(root, rows, problems)
    check_cheat_sheets(root, rows, problems)

    for problem in problems:
        print(f"action registry: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
