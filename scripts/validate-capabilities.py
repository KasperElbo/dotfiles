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
        elif row["provider"] not in {"unsupported", "windows-host"}:
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
