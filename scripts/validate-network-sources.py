#!/usr/bin/env python3
"""Validate the network-source provenance registry and enforce registration.

Two independent jobs:

1. The registry in ``config/network-sources.tsv`` is well formed: every source
   declares an owner, a provenance tier, a privilege level, an integrity
   mechanism consistent with its tier, an update cadence, a rollback strategy,
   and consumer files that actually exist.

2. No tracked file introduces a direct network source that the registry does
   not know about. Every network-executing construct -- ``curl``/``wget``,
   ``Invoke-WebRequest``/``Invoke-RestMethod``, a remote ``git clone``/
   ``fetch``, a remote release RPM, ``--repofrompath``, a DNF
   ``config-manager addrepo``, an ``rpm --import`` of a signing key, or a
   container image -- must carry a ``# network-source: <id>`` annotation naming
   a registered source. CI fails when a new one appears unregistered.

   A file is scanned by what it is, not only by its name: a scanned suffix, a
   path ``config/shell-file-roles.tsv`` classifies, or a shell or Python
   shebang each select it, so an extensionless command such as ``doctor`` or a
   stowed ``.local/bin`` helper is held to the same rule as an installer.

The annotation may sit on the same line or on any of the preceding comment
lines, so a single annotation can cover a short multi-line invocation.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import (  # noqa: E402
    ManifestSchemaError,
    read_tsv,
    role_pattern_matches,
    shell_file_role_patterns,
)

ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = pathlib.Path(
    os.environ.get("NETWORK_SOURCE_MANIFEST", ROOT / "config" / "network-sources.tsv")
)

FIELDS = [
    "id", "component", "owner", "kind", "url", "privilege", "tier",
    "requested", "resolved", "integrity", "cadence", "rollback", "consumers",
]

# Provenance/reproducibility tiers, strongest first. See docs/supply-chain.md.
TIERS = {
    "immutable-verified",
    "exact-commit",
    "exact-version",
    "version-line",
    "os-rolling",
    "reviewed-live",
}

INTEGRITY = {
    "sha256-pinned",
    "gpg-fingerprint-pinned",
    "image-digest-pinned",
    "git-tag-pinned",
    "git-commit-pinned",
    "repo-gpg",
    "registry-tls",
    "https-tls",
}

# An "immutable + cryptographically verified" claim is only honest when the
# integrity mechanism actually verifies content this repository pinned.
VERIFIED_INTEGRITY = {
    "sha256-pinned",
    "gpg-fingerprint-pinned",
    "image-digest-pinned",
}

EXACT_REF_INTEGRITY = VERIFIED_INTEGRITY | {"git-tag-pinned", "git-commit-pinned"}

PRIVILEGES = {"user", "root"}

KINDS = {
    "apt-repo", "archive", "container-image", "file", "git", "gpg-key",
    "json-api", "package-registry", "remote-script", "rpm-package", "rpm-repo",
}

ANNOTATION = re.compile(r"network-source:\s*([A-Za-z0-9,+-]+)")

# Reserved annotation for a flagged construct that reaches no external network:
# a loopback/in-container probe, or a transfer whose host is the machine under
# test. It still has to be written down, so adding one stays a reviewed act.
LOCAL_ONLY = "local-only"

# Constructs that reach the network directly and therefore need provenance.
# ``curl``/``wget`` only count as a network source when the line actually
# invokes them: a package-list entry or a ``require_command curl`` presence
# check names the tool without reaching anywhere.
NETWORK_PATTERNS = [
    (re.compile(r"(?<![\w./-])curl(?![\w-])\s+(?:-|\S+://)"), "curl"),
    (re.compile(r"(?<![\w./-])wget(?![\w-])\s+(?:-|\S+://)"), "wget"),
    (re.compile(r"Invoke-WebRequest|Invoke-RestMethod"), "powershell-download"),
    (re.compile(r"(?<![\w-])git\s+(?:-C\s+\S+\s+)?(?:clone|fetch|ls-remote)(?![\w-])"), "git-remote"),
    (re.compile(r"--repofrompath"), "repofrompath"),
    (re.compile(r"https://\S*\.rpm"), "remote-rpm"),
    # The two constructs that give a machine a new package trust root: a DNF
    # repository definition and a package-signing key. Both count however
    # their argument is spelled, because a variable holding a URL adds the
    # same trust as a literal one.
    (re.compile(r"config-manager\s+(?:addrepo|--add-repo)(?![\w-])"), "dnf-addrepo"),
    (re.compile(r"(?<![\w.-])rpm(?:keys)?\s+(?:-\S+\s+)*--import(?![\w-])"), "rpm-key-import"),
    (re.compile(r"(?:docker\.io|ghcr\.io|quay\.io|registry\.fedoraproject\.org)/\S+"), "container-image"),
]

# Directories whose network use is fixture/mock material rather than a real
# trust source. Test doubles must not require provenance registration, but the
# integration harness that pulls a real base image must.
EXEMPT_PREFIXES = ("tests/",)
EXEMPT_OVERRIDES = ("tests/integration/",)

# Files that describe the policy itself rather than performing a transfer.
POLICY_FILES = {
    "scripts/validate-network-sources.py",
    "scripts/render-supply-chain.py",
    "config/network-sources.tsv",
    "docs/supply-chain.md",
    "docs/supply-chain-sources.md",
    "common/lib/fetch.sh",
}

# Fast path: these suffixes are always scanned. Anything else is scanned when
# config/shell-file-roles.tsv classifies it (the validated inventory of every
# tracked shell file) or when its first line is a shell or Python shebang.
SCANNED_SUFFIXES = {".sh", ".ps1", ".yml", ".yaml", ".bash", ".zsh", ".py"}
SCANNED_SHEBANG = re.compile(r"^#!.*(?:\b(?:ba|z|da|k)?sh\b|\bpython[0-9.]*\b)")


def fail(message: str) -> None:
    print(f"network sources: {message}", file=sys.stderr)


def tracked_files() -> list[pathlib.Path]:
    output = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [pathlib.Path(name) for name in output.split("\0") if name]


def is_scanned(relative: str, full_path: pathlib.Path, role_patterns: tuple[str, ...]) -> bool:
    if pathlib.PurePosixPath(relative).suffix in SCANNED_SUFFIXES:
        return True
    if any(role_pattern_matches(pattern, relative) for pattern in role_patterns):
        return True
    # Only the first line decides, so a large document or binary is never read
    # whole just to be skipped.
    with full_path.open("rb") as stream:
        first_line = stream.readline(256)
    return bool(SCANNED_SHEBANG.match(first_line.decode("utf-8", errors="replace")))


def is_exempt(relative: str) -> bool:
    if relative in POLICY_FILES:
        return True
    if relative.startswith(EXEMPT_OVERRIDES):
        return False
    return relative.startswith(EXEMPT_PREFIXES)


def load_registry() -> tuple[list[dict[str, str]], int]:
    errors = 0
    try:
        rows = read_tsv(REGISTRY, FIELDS)
    except ManifestSchemaError as error:
        for message in error.messages:
            fail(message)
        return [], 1

    seen: set[str] = set()
    for line, row in enumerate(rows, 2):
        source_id = row["id"]
        if source_id == LOCAL_ONLY:
            fail(f"line {line}: {LOCAL_ONLY!r} is a reserved annotation, not a source id")
            errors += 1
        if source_id in seen:
            fail(f"line {line}: duplicate source id {source_id!r}")
            errors += 1
        seen.add(source_id)

        for column in FIELDS:
            if not (row[column] or "").strip():
                fail(f"line {line}: {source_id} has an empty {column}")
                errors += 1

        if row["kind"] not in KINDS:
            fail(f"line {line}: {source_id} has unknown kind {row['kind']!r}")
            errors += 1
        if row["privilege"] not in PRIVILEGES:
            fail(f"line {line}: {source_id} has invalid privilege {row['privilege']!r}")
            errors += 1
        if row["tier"] not in TIERS:
            fail(f"line {line}: {source_id} has unknown tier {row['tier']!r}")
            errors += 1
        if row["integrity"] not in INTEGRITY:
            fail(f"line {line}: {source_id} has unknown integrity {row['integrity']!r}")
            errors += 1

        if row["tier"] == "immutable-verified" and row["integrity"] not in VERIFIED_INTEGRITY:
            fail(
                f"line {line}: {source_id} claims immutable-verified but its integrity "
                f"is {row['integrity']!r}; only {sorted(VERIFIED_INTEGRITY)} actually verify content"
            )
            errors += 1
        if row["tier"] == "exact-commit" and row["integrity"] not in EXACT_REF_INTEGRITY:
            fail(f"line {line}: {source_id} claims exact-commit without a pinned ref")
            errors += 1

        # A wildcard is never an exact pin (issue #151 acceptance criteria).
        if row["tier"] in {"exact-version", "exact-commit"} and re.search(r"\.[xX*]\b|\*", row["requested"]):
            fail(f"line {line}: {source_id} uses a wildcard {row['requested']!r} as an exact pin")
            errors += 1

        for consumer in row["consumers"].split(","):
            consumer = consumer.strip()
            if consumer and not (ROOT / consumer).exists():
                fail(f"line {line}: {source_id} names a missing consumer: {consumer}")
                errors += 1

    return rows, errors


def scan_for_unregistered(known: set[str]) -> int:
    errors = 0
    role_patterns = shell_file_role_patterns(ROOT)
    for relative_path in tracked_files():
        relative = relative_path.as_posix()
        if is_exempt(relative):
            continue
        full_path = ROOT / relative_path
        if not full_path.is_file() or not is_scanned(relative, full_path, role_patterns):
            continue
        try:
            lines = full_path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue

        for index, line in enumerate(lines):
            stripped = line.strip()
            matched = next((label for pattern, label in NETWORK_PATTERNS if pattern.search(line)), None)
            if matched is None:
                continue
            # A line that only *names* the annotation, or mentions a command in
            # prose, still has to be annotated if it is not a comment.
            if stripped.startswith("#") and "network-source:" not in stripped:
                continue

            annotated: set[str] = set()
            for candidate in [line] + lines[max(0, index - 4):index][::-1]:
                match = ANNOTATION.search(candidate)
                if match:
                    annotated.update(match.group(1).split(","))
                    break

            if not annotated:
                fail(
                    f"{relative}:{index + 1}: unregistered {matched} network source; "
                    f"add it to config/network-sources.tsv and annotate the line "
                    f"with '# network-source: <id>'"
                )
                errors += 1
                continue

            for source_id in sorted(annotated):
                if source_id == LOCAL_ONLY:
                    continue
                if source_id not in known:
                    fail(f"{relative}:{index + 1}: unknown network-source id {source_id!r}")
                    errors += 1
    return errors


def main() -> int:
    rows, errors = load_registry()
    if not rows:
        return 1 if errors else 0
    errors += scan_for_unregistered({row["id"] for row in rows})
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
