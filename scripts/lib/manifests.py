#!/usr/bin/env python3
"""Shared manifest readers for the repository's Python tooling.

The platforms this repository supports are recorded once, as the `base`
capability rows of `config/capabilities.tsv`. Every generator and validator
that needs that list reads it from here instead of repeating the four names,
so adding or retiring a platform is one manifest edit rather than a hunt
through the scripts.

`scripts/validate-capabilities.py` deliberately does not use this helper: it
validates the very file the helper reads, and a check derived from its input
would agree with any typo it is meant to catch.
"""

from __future__ import annotations

import csv
import os
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CAPABILITY_MANIFEST = pathlib.Path(
    os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv")
)


def supported_platforms(manifest: pathlib.Path | None = None) -> tuple[str, ...]:
    """Platforms with an implemented `base` row, in manifest order.

    Manifest order is the order the generated documents present platforms in,
    so the manifest also decides how those pages read.
    """
    path = manifest or CAPABILITY_MANIFEST
    platforms: list[str] = []
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            if row["capability"] != "base" or row["status"] != "implemented":
                continue
            if row["platform"] not in platforms:
                platforms.append(row["platform"])
    return tuple(platforms)
