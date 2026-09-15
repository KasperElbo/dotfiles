#!/usr/bin/env python3
"""Validate the authoritative capability/provider contract."""

from __future__ import annotations

import csv
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = pathlib.Path(os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv"))
FIELDS = [
    "capability", "platform", "profile", "cli_flag", "default",
    "dependencies", "conflicts", "provider", "packages", "stow",
    "verifier", "state", "docs", "provenance", "status",
]
PLATFORMS = {"fedora", "fedora-wsl", "macos", "parrot-ctf"}
PLATFORM_VERIFIER = re.compile(r"^platforms/[^/]+/scripts/verify\.sh$")
# A platform verifier is the baseline capability from its first line, so
# requiring it to name "base" would only add noise. Every other capability it
# is declared for must be findable in the file.
VERIFIER_MENTION_EXEMPT = {"base"}


def split(value: str) -> list[str]:
    return [] if value == "-" else value.split(",")


def fail(message: str) -> None:
    print(f"capability manifest: {message}", file=sys.stderr)


def markdown_anchors(path: pathlib.Path) -> set[str]:
    anchors: set[str] = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*$", line)
        if not match:
            continue
        anchor = match.group(1).strip().lower()
        anchor = re.sub(r"[^\w\- ]", "", anchor)
        anchors.add(anchor.replace(" ", "-"))
    return anchors


def verifier_mentions(path: pathlib.Path, capability: str) -> bool:
    """Does this verifier say anywhere that it checks `capability`?

    A section that names the capability in its code or comments already says
    so; where the name does not appear naturally, the section carries a
    one-line `# verifies: <capability>` marker (see docs/capabilities.md).
    Both spellings are found by the same search: separators are normalized, so
    `dotnet-debug` is found in `check_easy_dotnet_debugger`, and a trailing
    suffix is allowed while a leading one is not, so `latex` is not satisfied
    by an unrelated `foolatex`.
    """
    text = re.sub(r"[^a-z0-9]+", "-", path.read_text(encoding="utf-8").lower())
    return re.search(rf"(?:^|-){re.escape(capability.lower())}", text) is not None


def main() -> int:
    errors = 0
    with MANIFEST.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != FIELDS:
            fail(f"unexpected columns: {reader.fieldnames}")
            return 1
        rows = list(reader)

    keys: set[tuple[str, str, str]] = set()
    rows_by_platform: dict[str, list[dict[str, str]]] = {}
    for line, row in enumerate(rows, 2):
        key = (row["capability"], row["platform"], row["profile"])
        if key in keys:
            fail(f"line {line}: duplicate provider ownership for {key}")
            errors += 1
        keys.add(key)
        rows_by_platform.setdefault(row["platform"], []).append(row)
        if row["platform"] not in PLATFORMS:
            fail(f"line {line}: unknown platform {row['platform']!r}")
            errors += 1
        if row["default"] not in {"auto", "enabled", "disabled"}:
            fail(f"line {line}: invalid default {row['default']!r}")
            errors += 1
        if row["status"] not in {"implemented", "unsupported"}:
            fail(f"line {line}: invalid status {row['status']!r}")
            errors += 1
        if row["status"] == "implemented":
            for column in ("provider", "verifier", "docs", "provenance"):
                if row[column] in {"", "-", "none", "unsupported"}:
                    fail(f"line {line}: implemented {key} lacks {column}")
                    errors += 1
            if not (ROOT / row["verifier"]).is_file():
                fail(f"line {line}: verifier does not exist: {row['verifier']}")
                errors += 1
            elif (
                PLATFORM_VERIFIER.match(row["verifier"])
                and row["capability"] not in VERIFIER_MENTION_EXEMPT
                and not verifier_mentions(ROOT / row["verifier"], row["capability"])
            ):
                fail(
                    f"line {line}: verifier {row['verifier']} never mentions "
                    f"{row['capability']}, the capability it is declared for; "
                    f"add the check, or mark the section that performs it with "
                    f"'# verifies: {row['capability']}'"
                )
                errors += 1
            for package in split(row["stow"]):
                portable = ROOT / package
                platform_package = ROOT / "platforms" / row["platform"] / "stow" / package
                if not portable.is_dir() and not platform_package.is_dir():
                    fail(f"line {line}: Stow package does not exist: {package}")
                    errors += 1
            docs_path, _, docs_anchor = row["docs"].partition("#")
            full_docs_path = ROOT / docs_path
            if not full_docs_path.is_file():
                fail(f"line {line}: documentation does not exist: {row['docs']}")
                errors += 1
            elif docs_anchor and docs_anchor not in markdown_anchors(full_docs_path):
                fail(f"line {line}: documentation anchor does not exist: {row['docs']}")
                errors += 1
        elif row["provider"] not in {"unsupported", "windows-host", "user-managed"}:
            fail(f"line {line}: unsupported {key} needs an explicit absence owner")
            errors += 1

    for platform, platform_rows in rows_by_platform.items():
        available = {row["capability"] for row in platform_rows if row["status"] == "implemented"}
        package_owners: dict[str, str] = {}
        for row in platform_rows:
            if row["status"] != "implemented":
                continue
            for dependency in split(row["dependencies"]):
                if dependency not in available:
                    fail(f"{platform}/{row['capability']}: missing dependency provider {dependency}")
                    errors += 1
            for package in split(row["packages"]):
                previous = package_owners.get(package)
                if previous and previous != row["capability"]:
                    fail(f"{platform}: package {package!r} owned by both {previous} and {row['capability']}")
                    errors += 1
                package_owners[package] = row["capability"]

    if PLATFORMS - set(rows_by_platform):
        fail(f"platforms missing from manifest: {', '.join(sorted(PLATFORMS - set(rows_by_platform)))}")
        errors += 1
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
