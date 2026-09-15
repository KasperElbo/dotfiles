#!/usr/bin/env python3
"""Shared manifest readers for the repository's Python tooling.

The platforms this repository supports are recorded once, as the `base`
capability rows of `config/capabilities.tsv`. Every generator and validator
that needs that list reads it from here instead of repeating the four names,
so adding or retiring a platform is one manifest edit rather than a hunt
through the scripts.

`scripts/validate-capabilities.py` deliberately does not use the capability
readers: it validates the very file they read, and a check derived from its
input would agree with any typo it is meant to catch. It does share the readers
of the *other* side of that comparison -- the Stow scripts and the mise
configuration -- so a generated page and the check against the manifest can
never parse those files two different ways.
"""

from __future__ import annotations

import csv
import os
import pathlib
import re
import tomllib

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


# The `packages=(…)` array a Stow script iterates, and every `packages+=(…)`
# append to it, conditional or not.
STOW_PACKAGES_ARRAY = re.compile(r"^\s*packages=\((?P<names>[^)]*)\)", re.MULTILINE)
STOW_PACKAGES_APPEND = re.compile(r"^\s*packages\+=\((?P<names>[^)]*)\)", re.MULTILINE)


def stow_packages(script: pathlib.Path) -> list[str]:
    """Every Stow package a script can deploy, including conditional appends."""
    text = script.read_text(encoding="utf-8")
    names: list[str] = []
    for pattern in (STOW_PACKAGES_ARRAY, STOW_PACKAGES_APPEND):
        for match in pattern.finditer(text):
            names.extend(match.group("names").split())
    if not names:
        raise SystemExit(f"No packages=( … ) array found in {script}")
    return names


def mise_tools(config: pathlib.Path) -> dict[str, str]:
    """The `[tools]` table of a mise configuration: tool spec to version."""
    with config.open("rb") as stream:
        return tomllib.load(stream).get("tools", {})


def mise_tool_package(spec: str) -> str:
    """The package a mise tool spec names, without its backend prefix.

    `dotnet:EasyDotnet` and `npm:@openai/codex` are the `EasyDotnet` and
    `@openai/codex` packages; a registry tool such as `lazygit` has no prefix.
    """
    return spec.partition(":")[2] or spec
