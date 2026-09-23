#!/usr/bin/env python3
"""Render the human-facing network-source table from network-sources.tsv."""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from generated import check_or_write  # noqa: E402
from manifests import read_tsv  # noqa: E402

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

live_manifest = root / "config" / "live-sources.tsv"

# What each integrity mechanism establishes *before* the content is used. Only
# a check against something this repository pinned, or a signature the package
# manager verifies against a trusted key, authenticates content; TLS proves
# only who served it. A digest recorded after a script ran is an audit record
# and appears nowhere in this column (#504).
CHECKED_BEFORE_USE = {
    "sha256-pinned": "yes: pinned SHA-256",
    "gpg-fingerprint-pinned": "yes: pinned key fingerprint",
    "image-digest-pinned": "yes: pinned image digest",
    "git-commit-pinned": "yes: pinned commit",
    "repo-gpg": "yes: repository signature",
    "git-tag-pinned": "no: pinned tag, which upstream can move",
    "registry-tls": "no: registry over TLS",
    "https-tls": "no: TLS only",
}

rows = read_tsv(manifest)
decisions = {row["id"]: row for row in read_tsv(live_manifest)}

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
        "| Source | Component | Owner | Kind | Privilege | Requested | Resolved | Integrity | Checked before use | Cadence |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in tier_rows:
        lines.append(
            "| `{id}` | {component} | {owner} | `{kind}` | `{privilege}` | `{requested}` | "
            "{resolved} | `{integrity}` | {checked} | {cadence} |".format(
                checked=CHECKED_BEFORE_USE[row["integrity"]], **row
            )
        )
    lines.append("")

lines += [
    "## Accepted live sources",
    "",
    "Nothing authenticates a `reviewed-live` source before it is used, so each one",
    "carries a recorded decision in `config/live-sources.tsv`. Where it is a script,",
    "it runs under the minimal installer environment of `common/lib/fetch.sh`.",
    "",
    "| Source | Runs as | Decision | Why | Environment it is given | Review and update |",
    "|---|---|---|---|---|---|",
]
for source_id in sorted(decisions):
    decision = decisions[source_id]
    lines.append(
        "| `{id}` | {executes} | `{decision}` | {reason} | {environment} | {review} |".format(
            **decision
        )
    )
lines.append("")

lines += ["## Rollback and recovery", "", "| Source | URL | Rollback | Consumers |", "|---|---|---|---|"]
for row in sorted(rows, key=lambda row: row["id"]):
    consumers = " ".join(f"`{name}`" for name in row["consumers"].split(","))
    lines.append(f"| `{row['id']}` | `{row['url']}` | {row['rollback']} | {consumers} |")

content = "\n".join(lines) + "\n"

raise SystemExit(
    check_or_write(
        target,
        content,
        sys.argv,
        stale="Generated network-source inventory is stale",
        remedy="./scripts/render-supply-chain.py",
    )
)
