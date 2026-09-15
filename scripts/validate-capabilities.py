#!/usr/bin/env python3
"""Validate the authoritative capability/provider contract.

`config/capabilities.tsv` and `config/install-options.tsv` describe the same
CLI contract from two directions: the first says what a capability is and how
it defaults, the second says what the parser accepts and what a machine may
remember. They are checked against each other here, so a default can never be
changed in one manifest alone.
"""

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

OPTION_MANIFEST = pathlib.Path(
    os.environ.get("INSTALL_OPTION_MANIFEST", ROOT / "config" / "install-options.tsv")
)
OPTION_FIELDS = [
    "platform", "option", "kind", "on_flag", "off_flag", "default",
    "values", "capability", "summary",
]

# Capabilities that own a CLI flag but deliberately have no persistent option
# row. `--dev-workflows` runs disposable smoke tests for one invocation; it is
# a transient execution control, so it belongs to no machine's remembered
# configuration and must not gain an install-options.tsv row.
TRANSIENT_CAPABILITIES = {"dev-workflows"}

# How a capability default maps onto the persistent option's default, per
# option kind. A `value` option is "off" by declaring no default at all.
OPTION_DEFAULTS = {
    ("enabled", "boolean"): {"true"},
    ("enabled", "tristate"): {"true"},
    ("disabled", "boolean"): {"false"},
    ("disabled", "tristate"): {"inherit"},
    ("disabled", "value"): {"-"},
    ("auto", "boolean"): {"auto"},
    ("auto", "tristate"): {"auto"},
}


def split(value: str) -> list[str]:
    return [] if value == "-" else value.split(",")


def fail(message: str) -> None:
    print(f"capability manifest: {message}", file=sys.stderr)


def fail_options(message: str) -> None:
    print(f"installer option manifest: {message}", file=sys.stderr)


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


def check_option_manifest(rows: list[dict[str, str]]) -> int:
    """Every flagged capability must have an option row that agrees with it."""
    errors = 0
    with OPTION_MANIFEST.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != OPTION_FIELDS:
            fail_options(f"unexpected columns: {reader.fieldnames}")
            return 1
        options = list(reader)

    by_flag = {(row["platform"], row["on_flag"]): row for row in options}
    for row in rows:
        if row["status"] != "implemented" or row["cli_flag"] in {"", "-"}:
            continue
        where = f"{row['platform']}/{row['capability']}"
        if row["capability"] in TRANSIENT_CAPABILITIES:
            if (row["platform"], row["cli_flag"]) in by_flag:
                fail_options(
                    f"{where}: {row['cli_flag']} is a transient control and must not "
                    "be a persistent option"
                )
                errors += 1
            continue
        option = by_flag.get((row["platform"], row["cli_flag"]))
        if option is None:
            fail_options(
                f"{where}: no persistent option declares {row['cli_flag']} on "
                f"{row['platform']}"
            )
            errors += 1
            continue
        expected = OPTION_DEFAULTS.get((row["default"], option["kind"]))
        if expected is None:
            fail_options(
                f"{row['platform']}/{option['option']}: capability default "
                f"{row['default']!r} has no meaning for a {option['kind']} option"
            )
            errors += 1
        elif option["default"] not in expected:
            fail_options(
                f"{row['platform']}/{option['option']}: option default "
                f"{option['default']!r} disagrees with capability "
                f"{row['capability']} default {row['default']!r} "
                f"(expected {' or '.join(sorted(expected))})"
            )
            errors += 1
    return errors


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

    errors += check_option_manifest(rows)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
