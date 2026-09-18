#!/usr/bin/env python3
"""Validate every bash platform's command requirements against capability package ownership."""

from __future__ import annotations

import os
import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import ManifestSchemaError, read_tsv  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]
CAPABILITIES = pathlib.Path(
    os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv")
)
COMMANDS = pathlib.Path(
    os.environ.get(
        "COMMAND_PROVIDER_MANIFEST",
        ROOT / "config" / "command-providers.tsv",
    )
)
PLATFORMS = {"fedora", "fedora-wsl", "macos", "parrot-ctf"}
CLASSIFICATIONS = {
    "bootstrap-prerequisite",
    "baseline-package",
    "repository-file",
    "supported-base",
}


def split(value: str) -> list[str]:
    return [] if value == "-" else value.split(",")


def fail(message: str) -> None:
    print(f"command provider closure: {message}", file=sys.stderr)


def main() -> int:
    errors = 0
    capabilities = read_tsv(CAPABILITIES)
    expected_fields = [
        "platform",
        "command",
        "provider",
        "owner",
        "required_by",
        "classification",
    ]
    try:
        commands = read_tsv(COMMANDS, expected_fields)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return 1

    rows = {
        (row["platform"], row["capability"]): row
        for row in capabilities
        if row["status"] == "implemented"
    }
    package_owners: dict[tuple[str, str], list[str]] = {}
    for row in capabilities:
        if row["status"] != "implemented":
            continue
        for package in split(row["packages"]):
            package_owners.setdefault((row["platform"], package), []).append(
                row["capability"]
            )

    def closure(platform: str, capability: str) -> set[str]:
        nonlocal errors
        resolved: set[str] = set()
        pending = [capability]
        while pending:
            current = pending.pop()
            if current in resolved:
                continue
            row = rows.get((platform, current))
            if row is None:
                fail(f"{platform}/{capability}: missing capability {current}")
                errors += 1
                break
            resolved.add(current)
            pending.extend(split(row["dependencies"]))
        return resolved

    seen_commands: set[tuple[str, str]] = set()
    covered_platforms: set[str] = set()
    for line, row in enumerate(commands, 2):
        platform = row["platform"]
        command = row["command"]
        provider = row["provider"]
        owner = row["owner"]
        classification = row["classification"]
        required_by = split(row["required_by"])
        covered_platforms.add(platform)

        if platform not in PLATFORMS:
            fail(f"line {line}: unsupported platform {platform!r}")
            errors += 1
        key = (platform, command)
        if key in seen_commands:
            fail(f"line {line}: command {command!r} has more than one provider on {platform}")
            errors += 1
        seen_commands.add(key)
        if classification not in CLASSIFICATIONS:
            fail(f"line {line}: unknown classification {classification!r}")
            errors += 1
        if (platform, owner) not in rows:
            fail(f"line {line}: owner capability {platform}/{owner} is not implemented")
            errors += 1

        for requiring_capability in required_by:
            selected = closure(platform, requiring_capability)
            if owner not in selected:
                fail(
                    f"{platform}/{requiring_capability}: command {command!r} is owned "
                    f"by {owner}, which is outside its dependency closure"
                )
                errors += 1

        owners = package_owners.get((platform, provider), [])
        if classification == "baseline-package":
            if owners != [owner]:
                rendered = ",".join(owners) if owners else "none"
                fail(
                    f"{platform}: command {command!r} provider {provider!r} must be "
                    f"owned exactly once by {owner}; owners={rendered}"
                )
                errors += 1
        elif classification == "repository-file":
            source = ROOT / provider
            if not source.is_file():
                fail(
                    f"{platform}: repository provider for {command!r} does not exist: "
                    f"{provider}"
                )
                errors += 1
        elif owners and owner not in owners:
            fail(
                f"{platform}: preinstalled provider {provider!r} for {command!r} "
                f"conflicts with capability owner(s) {','.join(owners)}"
            )
            errors += 1

    for platform in PLATFORMS - covered_platforms:
        fail(f"platform missing from command provider manifest: {platform}")
        errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
