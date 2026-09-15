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


def platform_profiles(manifest: pathlib.Path | None = None) -> dict[str, str]:
    """Each supported platform mapped to the profile its `base` row declares.

    The registry of user actions uses the profile names on the right-hand side
    as platform sentinels: an action recorded as `platform=workstation` exists
    on every platform whose `base` row is a workstation, which today is every
    platform except the reduced CTF guest.
    """
    path = manifest or CAPABILITY_MANIFEST
    profiles: dict[str, str] = {}
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            if row["capability"] != "base" or row["status"] != "implemented":
                continue
            profiles.setdefault(row["platform"], row["profile"])
    return profiles


def capability_names(manifest: pathlib.Path | None = None) -> tuple[str, ...]:
    """Every capability name the manifest declares, in manifest order."""
    path = manifest or CAPABILITY_MANIFEST
    names: list[str] = []
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            if row["capability"] not in names:
                names.append(row["capability"])
    return tuple(names)
