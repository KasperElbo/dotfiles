#!/usr/bin/env python3
"""Shared manifest readers for the repository's Python tooling.

`read_tsv` is how every validator and generator opens a `config/*.tsv`. The
quoting decision and the per-row column count are made here, once, because the
same bytes read three ways is a defect the registries cannot detect about
themselves: the shell libraries read these files with `awk -F '\t'`, and a
validator that disagreed with them would approve one reading of a row while the
installer acted on another.

The platforms this repository supports are recorded once, as the `base`
capability rows of `config/capabilities.tsv`. Every generator and validator
that needs that list reads it from here instead of repeating the names, so
adding or retiring a platform is one manifest edit rather than a hunt through
the scripts. Two lists come out of those rows and they are not the same one:
`registered_platforms` is every platform the registry models, and
`supported_platforms` is the subset `./install.sh --platform` can run.

`scripts/validate-capabilities.py` deliberately does not use the capability
readers: it validates the very file they read, and a check derived from its
input would agree with any typo it is meant to catch. `read_tsv` is not such a
derivation -- it decides where a row's fields are, not what they are allowed to
say -- so that validator shares it like every other caller. It also shares the
readers of the *other* side of its comparison -- the Stow scripts and the mise
configuration -- so a generated page and the check against the manifest can
never parse those files two different ways.
"""

from __future__ import annotations

import csv
import fnmatch
import os
import pathlib
import re
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
CAPABILITY_MANIFEST = pathlib.Path(
    os.environ.get("CAPABILITY_MANIFEST", ROOT / "config" / "capabilities.tsv")
)
SHELL_FILE_ROLES_MANIFEST = pathlib.Path("config") / "shell-file-roles.tsv"


class ManifestSchemaError(Exception):
    """A tab-separated manifest does not match the schema its reader declares.

    The messages are phrased for a validator's own reporter rather than printed
    here, so each caller keeps the prefix and the exit convention it already
    had.
    """

    def __init__(self, messages: list[str]) -> None:
        super().__init__("; ".join(messages))
        self.messages = messages


def read_tsv(
    path: pathlib.Path, fields: list[str] | None = None
) -> list[dict[str, str]]:
    """Every row of a tab-separated registry, with one quoting decision.

    Quoting is disabled. The registries are tab-separated, never quoted, and a
    value is free to begin with a double quote --- `config/actions.tsv` records
    a Waybar `"on-click"` pattern that does. Python's default dialect would
    treat that quote as an opening delimiter and swallow the tabs after it into
    one field, while `awk -F '\t'`, which the shell libraries read the same
    files with, would not. Reading every manifest with `QUOTE_NONE` is what
    makes the two agree.

    Each row is also checked for arity, which `csv.DictReader` alone does not
    do: a trailing extra column lands under the `None` key and a missing one
    leaves a `None` value, and both are reported here as schema errors naming
    the line, rather than reaching a field check as an unexplained value.

    `fields`, when given, is the exact header the caller expects.
    """
    messages: list[str] = []
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE)
        if fields is not None and reader.fieldnames != fields:
            raise ManifestSchemaError([f"unexpected columns: {reader.fieldnames}"])
        rows = list(reader)

    header = reader.fieldnames or []
    for line, row in enumerate(rows, 2):
        extra = row.pop(None, None)
        if extra:
            messages.append(
                f"line {line}: {len(header) + len(extra)} columns, "
                f"expected {len(header)}: {extra!r} is past the last column"
            )
        missing = [name for name, value in row.items() if value is None]
        if missing:
            messages.append(
                f"line {line}: columns {', '.join(missing)} are missing; "
                f"a row must carry every one of the {len(header)} columns"
            )
    if messages:
        raise ManifestSchemaError(messages)
    return rows


def registered_platforms(manifest: pathlib.Path | None = None) -> tuple[str, ...]:
    """Every platform the manifest models at all, in manifest order.

    The registry models one platform more than `./install.sh` drives: the
    Windows host is installed by `platforms/windows/install.ps1` and verified
    by `platforms/windows/verify.ps1`, so it is answerable to the same rows,
    provider ownership and verifier column as the four Bash platforms without
    being a `--platform` name. Pages *about the registry* -- the capability
    matrix and the verifier reference -- are about what it models, so they read
    this; pages about the portable installer read supported_platforms().
    """
    platforms: list[str] = []
    for row in read_tsv(manifest or CAPABILITY_MANIFEST):
        if row["platform"] not in platforms:
            platforms.append(row["platform"])
    return tuple(platforms)


def has_portable_installer(platform: str) -> bool:
    """Is this platform one `./install.sh --platform NAME` can run?

    That entry point resolves the name to `platforms/NAME/install.sh` and
    executes it, so a platform without that script is not one it accepts, no
    matter what the manifest says it implements.
    """
    return (ROOT / "platforms" / platform / "install.sh").is_file()


def supported_platforms(manifest: pathlib.Path | None = None) -> tuple[str, ...]:
    """Platforms the portable installer supports, in manifest order.

    An implemented `base` row *and* a `platforms/<name>/install.sh` for
    `./install.sh --platform` to run: both, because the Windows host has the
    first without the second. Manifest order is the order the generated
    documents present platforms in, so the manifest also decides how those
    pages read.
    """
    platforms: list[str] = []
    for row in read_tsv(manifest or CAPABILITY_MANIFEST):
        if row["capability"] != "base" or row["status"] != "implemented":
            continue
        if row["platform"] not in platforms and has_portable_installer(row["platform"]):
            platforms.append(row["platform"])
    return tuple(platforms)


def platform_profiles(manifest: pathlib.Path | None = None) -> dict[str, str]:
    """Each supported platform mapped to the profile its `base` row declares.

    The registry of user actions uses the profile names on the right-hand side
    as platform sentinels: an action recorded as `platform=workstation` exists
    on every platform whose `base` row is a workstation, which today is every
    platform except the reduced CTF guest. "Supported" is supported_platforms()'
    sense, so the Windows host's profile is not a sentinel: this repository
    deploys no shell, editor or multiplexer bindings there.
    """
    profiles: dict[str, str] = {}
    for row in read_tsv(manifest or CAPABILITY_MANIFEST):
        if row["capability"] != "base" or row["status"] != "implemented":
            continue
        if not has_portable_installer(row["platform"]):
            continue
        profiles.setdefault(row["platform"], row["profile"])
    return profiles


def capability_names(manifest: pathlib.Path | None = None) -> tuple[str, ...]:
    """Every capability name the manifest declares, in manifest order."""
    names: list[str] = []
    for row in read_tsv(manifest or CAPABILITY_MANIFEST):
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


def shell_file_role_patterns(root: pathlib.Path = ROOT) -> tuple[str, ...]:
    """Every path pattern `config/shell-file-roles.tsv` classifies under `root`."""
    return tuple(row["pattern"] for row in read_tsv(root / SHELL_FILE_ROLES_MANIFEST))


def role_pattern_matches(pattern: str, name: str) -> bool:
    """Path-aware globbing: `*` stays inside one path segment, `**` spans them.

    fnmatch alone would let `common/*.sh` claim `common/lib/common.sh`, which
    is exactly the ambiguity the shell-file role inventory exists to remove.
    """
    pattern_parts = pattern.split("/")
    name_parts = name.split("/")
    if pattern_parts and pattern_parts[-1] == "**":
        return (
            len(name_parts) > len(pattern_parts) - 1
            and all(
                fnmatch.fnmatchcase(actual, expected)
                for expected, actual in zip(pattern_parts[:-1], name_parts)
            )
        )
    if len(pattern_parts) != len(name_parts):
        return False
    return all(
        fnmatch.fnmatchcase(actual, expected)
        for expected, actual in zip(pattern_parts, name_parts)
    )
