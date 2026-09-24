#!/usr/bin/env python3
"""Every manual-bump source must declare how its staleness is noticed.

`config/network-sources.tsv` records a cadence for each source. A rolling
cadence is self-announcing: the package manager, the registry or the version
line tells the machine that something moved. `manual-bump` is the cadence with
no such mechanism, and before `config/pin-freshness.tsv` existed there was
nothing anywhere in the repository that would ever say a pinned tag or digest
had fallen behind its upstream. A pin got bumped when something else broke.

This validator is what stops that hole reopening. Three jobs:

1. **The two manifests agree on the set.** Every `manual-bump` source has
   exactly one freshness row, and no other source has one. Adding a pinned
   artifact therefore cannot be done without saying how a newer release would
   be noticed -- or recording, in the row itself, that it cannot be and why.

2. **A probe row can actually be run.** Its target is an HTTPS URL, its
   `pin_file` exists, and that file states `pin_key="..."` exactly once.
   `scripts/check-pin-freshness.sh` reads the pinned value out of the
   installer rather than from a value repeated in a manifest, so a bump cannot
   leave the report comparing against the previous release -- but that only
   holds while the assignment it reads is really there, which is checked here
   rather than discovered on the monthly run.

3. **The registry has not drifted from the installer.** Where a source's
   `requested` column states the pin as a literal rather than in prose, it must
   equal what the installer actually pins. That is a claim the rendered
   supply-chain inventory publishes, and it was previously true only by
   everyone remembering to edit both.

A `none` probe is a first-class answer, not a failure: some pins are not refs
in a git repository and cannot be read this way. It must carry a reason, and
`scripts/check-pin-freshness.sh` prints that reason in its report, so a source
this mechanism cannot ask about stays visible rather than quietly absent.

Usage:
    scripts/validate-pin-freshness.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402

FRESHNESS_MANIFEST = pathlib.Path("config") / "pin-freshness.tsv"
NETWORK_MANIFEST = pathlib.Path("config") / "network-sources.tsv"

FIELDS = ["source", "probe", "target", "pin_file", "pin_key", "note"]
NETWORK_FIELDS = [
    "id", "component", "owner", "kind", "url", "privilege", "tier",
    "requested", "resolved", "integrity", "cadence", "rollback", "consumers",
]

MANUAL = "manual-bump"
PROBES = {"git-tags", "git-head", "none"}
EMPTY = "-"

# A shell variable name, which is what check-pin-freshness.sh interpolates into
# the sed script that reads the pin. Restricting it here is what keeps that
# interpolation safe as well as readable.
PIN_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# A `requested` value that states the pin itself rather than describing it.
# "pinned release + sha256" and "5.5.0 compiler" describe; "v2.3.0",
# "3.1.3-1062" and a 40-character commit state.
LITERAL_PIN = re.compile(r"^v?[0-9][0-9A-Za-z.-]*$|^[0-9a-f]{40}$")


def assignment(path: pathlib.Path, key: str) -> list[str]:
    """Every `key="value"` assignment in a file, as the report reads them.

    A PowerShell data file spells the same thing `Key = 'value'`, indented,
    and the report reads a `.psd1` pin that way.
    """
    if path.suffix == ".psd1":
        pattern = re.compile(rf"^\s*{re.escape(key)}\s*=\s*'([^']*)'\s*$", re.MULTILINE)
    else:
        pattern = re.compile(rf'^{re.escape(key)}="([^"]*)"$', re.MULTILINE)
    return pattern.findall(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    problems: list[str] = []

    try:
        rows = read_tsv(root / FRESHNESS_MANIFEST, FIELDS)
        sources = read_tsv(root / NETWORK_MANIFEST, NETWORK_FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            print(f"pin freshness: {message}", file=sys.stderr)
        return 1

    registry = {row["id"]: row for row in sources}
    manual = {row["id"] for row in sources if row["cadence"] == MANUAL}

    declared: set[str] = set()
    for line, row in enumerate(rows, 2):
        source = row["source"]

        for column in FIELDS:
            if not (row[column] or "").strip():
                problems.append(f"line {line}: {source} has an empty {column}")

        if source in declared:
            problems.append(f"line {line}: duplicate freshness row for {source!r}")
        declared.add(source)

        if source not in registry:
            problems.append(
                f"line {line}: {source!r} is not a source in {NETWORK_MANIFEST}"
            )
            continue
        if source not in manual:
            problems.append(
                f"line {line}: {source!r} has cadence {registry[source]['cadence']!r}, "
                f"which announces its own updates; only {MANUAL} sources need a "
                f"freshness row"
            )
            continue

        probe = row["probe"]
        if probe not in PROBES:
            problems.append(
                f"line {line}: {source} has unknown probe {probe!r} "
                f"(expected one of {', '.join(sorted(PROBES))})"
            )
            continue

        if probe == "none":
            for column in ("target", "pin_file", "pin_key"):
                if row[column] != EMPTY:
                    problems.append(
                        f"line {line}: {source} is not probed, so its {column} must be "
                        f"{EMPTY!r}, not {row[column]!r}"
                    )
            if row["note"] == EMPTY:
                problems.append(
                    f"line {line}: {source} is not probed and must say why in its note; "
                    f"an unexplained gap is how this one opened"
                )
            continue

        if row["note"] != EMPTY and not row["note"].endswith("."):
            problems.append(f"line {line}: {source}'s note must be a sentence ending in '.'")

        if not row["target"].startswith("https://"):
            problems.append(
                f"line {line}: {source} has target {row['target']!r}; a probe target "
                f"must be an https URL"
            )

        if not PIN_KEY.match(row["pin_key"]):
            problems.append(
                f"line {line}: {source} has pin_key {row['pin_key']!r}, which is not a "
                f"shell variable name"
            )
            continue

        pin_file = root / row["pin_file"]
        if not pin_file.is_file():
            problems.append(f"line {line}: {source} names a missing pin_file: {row['pin_file']}")
            continue

        found = assignment(pin_file, row["pin_key"])
        if len(found) != 1:
            problems.append(
                f"line {line}: {row['pin_file']} states "
                f'{row["pin_key"]}="..." {len(found)} times; '
                f"the report reads exactly one assignment"
            )
            continue

        requested = registry[source]["requested"]
        if LITERAL_PIN.match(requested) and requested != found[0]:
            problems.append(
                f"line {line}: {NETWORK_MANIFEST} records {source} as pinned to "
                f"{requested!r}, but {row['pin_file']} pins {found[0]!r}"
            )

    for source in sorted(manual - declared):
        problems.append(
            f"{NETWORK_MANIFEST}: {source!r} has cadence {MANUAL} but no row in "
            f"{FRESHNESS_MANIFEST}; give it a probe, or a 'none' row saying why its "
            f"staleness cannot be noticed"
        )

    for problem in problems:
        print(f"pin freshness: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
