#!/usr/bin/env python3
"""Render the human-facing network-source table from network-sources.tsv."""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import check_or_write, read_tsv  # noqa: E402

root = pathlib.Path(__file__).resolve().parents[1]
manifest = root / "config" / "network-sources.tsv"
target = root / "docs" / "supply-chain-sources.md"

TIER_ORDER = [
    "immutable-verified",
    "exact-commit",
    "exact-version",
    "version-line",
    "os-rolling",
    "reviewed-live",
]

rows = read_tsv(manifest)

lines = [
    "# Generated network-source inventory",
    "",
    "Generated from `config/network-sources.tsv`; do not edit this table by hand.",
    "Run `./scripts/render-supply-chain.py` after changing the manifest.",
    "",
    "The tiers themselves, and what the repository does and does not claim about",
    "reproducibility, are described in [supply-chain.md](supply-chain.md).",
    "",
]

for tier in TIER_ORDER:
    tier_rows = sorted((row for row in rows if row["tier"] == tier), key=lambda row: row["id"])
    if not tier_rows:
        continue
    lines += [
        f"## Tier: `{tier}`",
        "",
        "| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Cadence |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for row in tier_rows:
        lines.append(
            "| `{id}` | {component} | {owner} | `{kind}` | `{privilege}` | `{requested}` | "
            "{resolved} | `{integrity}` | {cadence} |".format(**row)
        )
    lines.append("")

lines += ["## Rollback and recovery", "", "| Source | URL | Rollback | Consumers |", "|---|---|---|---|"]
for row in sorted(rows, key=lambda row: row["id"]):
    consumers = " ".join(f"`{name}`" for name in row["consumers"].split(","))
    lines.append(f"| `{row['id']}` | `{row['url']}` | {row['rollback']} | {consumers} |")

content = "\n".join(lines) + "\n"

raise SystemExit(check_or_write(target, content, sys.argv))
