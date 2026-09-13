#!/usr/bin/env python3
"""Render the human-facing support/ownership table from capabilities.tsv."""

from __future__ import annotations

import csv
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
manifest = root / "config" / "capabilities.tsv"
target = root / "docs" / "capability-matrix.md"
platforms = ["fedora", "fedora-wsl", "macos", "parrot-ctf"]

with manifest.open(newline="", encoding="utf-8") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))

capabilities = sorted({row["capability"] for row in rows})
lookup = {(row["capability"], row["platform"]): row for row in rows}
lines = [
    "# Generated capability support matrix",
    "",
    "Generated from `config/capabilities.tsv`; do not edit this table by hand.",
    "",
    "| Capability | Fedora | Fedora WSL | macOS | Parrot CTF |",
    "|---|---|---|---|---|",
]
for capability in capabilities:
    cells = []
    for platform in platforms:
        row = lookup.get((capability, platform))
        if row is None:
            cells.append("—")
        elif row["status"] == "implemented":
            cells.append(f"✓ `{row['provider']}`")
        else:
            cells.append(f"— {row['provider']}")
    lines.append(f"| `{capability}` | " + " | ".join(cells) + " |")
content = "\n".join(lines) + "\n"

if "--check" in sys.argv:
    if not target.exists() or target.read_text(encoding="utf-8") != content:
        print(f"Generated capability matrix is stale: {target}", file=sys.stderr)
        raise SystemExit(1)
else:
    target.write_text(content, encoding="utf-8")
