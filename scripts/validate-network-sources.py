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
   known basename such as ``Brewfile``, a path
   ``config/shell-file-roles.tsv`` classifies, or a shell or Python shebang
   each select it, so an extensionless command such as ``doctor`` or a stowed
   ``.local/bin`` helper is held to the same rule as an installer.

The annotation may sit on the same line or on any of the four preceding lines,
so a single annotation can cover a short multi-line invocation. Proximity
alone is not enough: when the construct names a host outright, the annotations
covering it must name a source served by that host, so a new download dropped
under an unrelated comment cannot inherit its provenance.
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

# The `resolved` column of a digest-pinned image row.
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")

KINDS = {
    "apt-repo", "archive", "container-image", "file", "git", "gpg-key",
    "json-api", "package-registry", "remote-script", "rpm-package", "rpm-repo",
}

ANNOTATION = re.compile(r"network-source:\s*([A-Za-z0-9,+-]+)")
# How far above a construct an annotation may be written, and what it may be
# written through: comment lines in any of this repository's languages, and
# blank lines between them.
ANNOTATION_LOOKBACK = 4
COMMENT_LINE = re.compile(r"(?:#|--|//|;)")
# A line the next one continues, so the two are one construct: a backslash, or
# an && / || left hanging at the end of a condition. An annotation belongs
# above the first line of such a construct, not between its halves, where no
# shell would let a comment go anyway. A trailing comma is deliberately not
# here: list elements are written one per line, and treating each as a
# continuation of the one above would hand every element the first one's
# annotation, which is the inheritance this file exists to refuse.
CONTINUED_LINE = re.compile(r"(?:\\|&&|\|\|)$")

# Reserved annotation for a flagged construct that reaches no external network:
# a loopback/in-container probe, or a transfer whose host is the machine under
# test. It still has to be written down, so adding one stays a reviewed act.
LOCAL_ONLY = "local-only"

# Reserved annotation for a transfer primitive: the construct downloads a URL
# its caller passes in, so the provenance belongs to the call site, which is
# annotated with the source it actually fetches. It does not excuse a host
# written into the primitive itself -- a literal URL there names a source of
# its own and has to be registered like any other.
CALLER_PROVIDED = "caller-provided"

RESERVED_ANNOTATIONS = {LOCAL_ONLY, CALLER_PROVIDED}

# ``owner/name:tag`` or ``owner/name@sha256:...``, with or without a leading
# registry host.
IMAGE_REFERENCE = (
    r"(?<![\w/@:.$-])[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)+"
    r"(?::[A-Za-z0-9][\w.-]*|@sha256:[0-9a-f]{64})"
)

# Constructs that reach the network directly and therefore need provenance.
# ``curl``/``wget`` only count as a network source when the line actually
# invokes them: a package-list entry or a ``require_command curl`` presence
# check names the tool without reaching anywhere.
NETWORK_PATTERNS = [
    (re.compile(r"(?<![\w./-])curl(?![\w-])\s+(?:-|\S+://)"), "curl"),
    (re.compile(r"(?<![\w./-])wget(?![\w-])\s+(?:-|\S+://)"), "wget"),
    (re.compile(r"Invoke-WebRequest|Invoke-RestMethod"), "powershell-download"),
    (re.compile(r"(?<![\w-])git\s+(?:-C\s+\S+\s+)?(?:clone|fetch|ls-remote)(?![\w-])"), "git-remote"),
    # The same clone written as an argument vector rather than a command line,
    # which is how Lua, Python and PowerShell spawn git. ``vim.fn.system({
    # "git", "clone", ... })`` in the Neovim bootstrap is exactly this shape.
    (
        re.compile(
            r"""["']git["']\s*,\s*(?:["']-C["']\s*,\s*[^,]+,\s*)?"""
            r"""["'](?:clone|fetch|ls-remote)["']"""
        ),
        "git-remote",
    ),
    # A download written the same way. The git argv form was here and this one
    # was not, so ``vim.fn.system({ "curl", "-fsSL", url })`` in a Lua file
    # reached the network with nothing to flag it.
    (re.compile(r"""["']curl["']\s*,"""), "curl"),
    (re.compile(r"--repofrompath"), "repofrompath"),
    (re.compile(r"https://\S*\.rpm"), "remote-rpm"),
    # The two constructs that give a machine a new package trust root: a DNF
    # repository definition and a package-signing key. Both count however
    # their argument is spelled, because a variable holding a URL adds the
    # same trust as a literal one.
    (re.compile(r"config-manager\s+(?:addrepo|--add-repo)(?![\w-])"), "dnf-addrepo"),
    (re.compile(r"(?<![\w.-])rpm(?:keys)?\s+(?:-\S+\s+)*--import(?![\w-])"), "rpm-key-import"),
    # A Homebrew tap is a git clone of a third-party repository, and every
    # formula in it is Ruby that Homebrew runs at install time -- a trust root
    # with its own owner. ``Brewfile`` has been in SCANNED_NAMES since this
    # validator was written, on exactly that reasoning, but no pattern here
    # could match a line one holds, so the entry answered nothing: a hostile
    # ``tap`` plus two packages from it passed the gate silently. The second
    # pattern is a package pulled from a non-core tap, which is the same trust
    # root reached without naming it on its own line. Neither form carries a
    # scheme, so literal_hosts finds no host and the annotation alone covers
    # them, which is the right answer for a reference that is not a URL.
    # A Mason registry is a trust root of the same kind: every LSP server and
    # debug adapter Mason installs is resolved through the list, and one of
    # this repository's two is a personal fork. ``github:owner/repo`` carries
    # no scheme, so literal_hosts finds no host in it and the repository it
    # names is what the annotation has to be checked against.
    (re.compile(r"""["']github:[\w.-]+/[\w.-]+["']"""), "package-registry"),
    (re.compile(r"""^\s*tap\s+["'][\w.-]+/[\w.-]+["']"""), "homebrew-tap"),
    (re.compile(r"""^\s*(?:brew|cask)\s+["'][\w.-]+/[\w.-]+/"""), "homebrew-tap-package"),
    (re.compile(r"(?:docker\.io|ghcr\.io|quay\.io|registry\.fedoraproject\.org)/\S+"), "container-image"),
    # Docker Hub shorthand: ``parrotsec/core:latest`` names a registry-qualified
    # image with the registry left out, and pulls exactly as much code as the
    # long form. A bare ``owner/name:tag`` is too common in ordinary text to
    # flag on its own (MIME types and desktop associations read the same), so
    # it counts when the line puts it in a container context: a container
    # command, a workflow ``container:``/``image:`` key, or a build ``FROM``.
    (
        re.compile(
            r"(?:(?<![\w-])(?:docker|podman)\s+(?:run|pull|create|build|image)(?![\w-])"
            r"|^\s*(?:container|image)\s*:\s*"
            r"|^\s*(?:FROM|ARG\s+BASE_IMAGE=))"
            r".*?" + IMAGE_REFERENCE
        ),
        "container-image",
    ),
]

# Directories whose network use is fixture/mock material rather than a real
# trust source. Test doubles must not require provenance registration, but the
# integration harness that pulls a real base image must.
EXEMPT_PREFIXES = ("tests/",)
EXEMPT_OVERRIDES = ("tests/integration/",)

# Files that describe the policy itself rather than performing a transfer.
# ``common/lib/fetch.sh`` is deliberately absent: it is the library that
# performs every download in the repository, so exempting it would exempt the
# one file a hardcoded URL would do the most damage in. Its primitives take
# the URL from their caller and say so with ``# network-source:
# caller-provided``.
POLICY_FILES = {
    "scripts/validate-network-sources.py",
    "scripts/render-supply-chain.py",
    "config/network-sources.tsv",
    "docs/supply-chain.md",
    "docs/supply-chain-sources.md",
}

# Fast path: these suffixes and these basenames are always scanned. Anything
# else is scanned when config/shell-file-roles.tsv classifies it (the
# validated inventory of every tracked shell file) or when its first line is a
# shell or Python shebang.
SCANNED_SUFFIXES = {".sh", ".ps1", ".yml", ".yaml", ".bash", ".zsh", ".py", ".lua"}
# A package manifest is code for this purpose: a Brewfile names the taps and
# formulae Homebrew then downloads and runs.
SCANNED_NAMES = {"Brewfile"}
SCANNED_SHEBANG = re.compile(r"^#!.*(?:\b(?:ba|z|da|k)?sh\b|\bpython[0-9.]*\b)")


# Hosts written out in full. A scheme covers every URL; the second form is the
# registry of a container reference, which carries no scheme, and is only read
# where an image reference is what matched.
SCHEME_HOST = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://(?P<host>[^/\s\"'`<>|)\\]+)")
IMAGE_HOST = re.compile(
    r"(?<![\w.:/@-])(?P<host>(?:[a-z0-9-]+\.)+[a-z]{2,}(?::[0-9]+)?)/[a-z0-9]"
)
# Hosts that are the machine itself: what `local-only` is allowed to cover.
LOCAL_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"}

# A Homebrew tap reference carries no scheme and no host, so the host check
# below has nothing to compare and an annotation would cover any tap written
# near it. What a tap names instead is a repository: `tap "owner/name"` clones
# https://github.com/owner/homebrew-name, and a `brew`/`cask` argument with two
# slashes pulls a package from that same clone. These two read both ends of
# that identity so a tap is covered only by a source that is actually it.
PACKAGE_REGISTRY_LABEL = "package-registry"
PACKAGE_REGISTRY_REFERENCE = re.compile(
    r"""["']github:(?P<owner>[\w.-]+)/(?P<name>[\w.-]+)["']"""
)
GITHUB_REPOSITORY = re.compile(
    r"^https://github\.com/(?P<owner>[\w.-]+)/(?P<name>[\w.-]+?)(?:\.git)?/?$"
)

HOMEBREW_TAP_LABELS = {"homebrew-tap", "homebrew-tap-package"}
HOMEBREW_TAP_REFERENCE = re.compile(
    r"""^\s*(?:tap|brew|cask)\s+["'](?P<owner>[\w.-]+)/(?P<name>[\w.-]+)["'/]"""
)
HOMEBREW_TAP_REPOSITORY = re.compile(
    r"^https://github\.com/(?P<owner>[\w.-]+)/homebrew-(?P<name>[\w.-]+?)(?:\.git)?/?$"
)


def fail(message: str) -> None:
    print(f"network sources: {message}", file=sys.stderr)


def bare_host(authority: str) -> str:
    """The host of a URL authority: no credentials, no port, lower case."""
    host = authority.rsplit("@", 1)[-1]
    if host.startswith("["):
        return host.partition("]")[0].lower() + "]"
    return host.split(":", 1)[0].rstrip(".").lower()


def literal_hosts(text: str, *, image_reference: bool = False) -> set[str]:
    """Every host this text names outright.

    A host assembled from a variable is not one: the validator cannot know
    what it expands to, and guessing would either wave transfers through or
    fail honest ones.
    """
    matches = list(SCHEME_HOST.finditer(text))
    if image_reference:
        matches += list(IMAGE_HOST.finditer(text))
    found = set()
    for match in matches:
        host = bare_host(match.group("host"))
        if host and not re.search(r"[${}*]", host):
            found.add(host)
    return found


def construct_text(lines: list[str], index: int) -> str:
    """The construct's own line plus the lines a backslash joins to it.

    A multi-line invocation usually carries its URL on a continuation line, so
    the host belongs to the whole construct rather than to its first line.
    """
    text = lines[index]
    cursor = index
    while text.rstrip().endswith("\\") and cursor + 1 < len(lines):
        cursor += 1
        text = f"{text}\n{lines[cursor]}"
    return text


def source_hosts(rows: list[dict[str, str]]) -> dict[str, set[str]]:
    """The hosts each registered source is served from."""
    return {
        row["id"]: literal_hosts(row["url"], image_reference=True) for row in rows
    }


def named_taps(text: str) -> set[str]:
    """Every Homebrew tap this text names, as ``owner/name``, lower case."""
    found = set()
    for line in text.splitlines():
        match = HOMEBREW_TAP_REFERENCE.match(line)
        if match:
            found.add(f"{match.group('owner').lower()}/{match.group('name').lower()}")
    return found


def source_taps(rows: list[dict[str, str]]) -> dict[str, set[str]]:
    """The Homebrew tap each registered source is, when its url is one."""
    taps = {}
    for row in rows:
        match = HOMEBREW_TAP_REPOSITORY.match(row["url"].strip())
        taps[row["id"]] = (
            {f"{match.group('owner').lower()}/{match.group('name').lower()}"}
            if match
            else set()
        )
    return taps


def named_registries(text: str) -> set[str]:
    """Every ``github:owner/repo`` registry this text names, lower case."""
    return {
        f"{match.group('owner').lower()}/{match.group('name').lower()}"
        for match in PACKAGE_REGISTRY_REFERENCE.finditer(text)
    }


def source_repositories(rows: list[dict[str, str]]) -> dict[str, set[str]]:
    """The GitHub repository each registered source is, when its url is one."""
    repositories = {}
    for row in rows:
        match = GITHUB_REPOSITORY.match(row["url"].strip())
        repositories[row["id"]] = (
            {f"{match.group('owner').lower()}/{match.group('name').lower()}"}
            if match
            else set()
        )
    return repositories


def tracked_files() -> list[pathlib.Path]:
    output = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [pathlib.Path(name) for name in output.split("\0") if name]


def is_scanned(relative: str, full_path: pathlib.Path, role_patterns: tuple[str, ...]) -> bool:
    name = pathlib.PurePosixPath(relative)
    if name.suffix in SCANNED_SUFFIXES or name.name in SCANNED_NAMES:
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

        # A digest pin the consumer does not use is a claim about a run that
        # never happens: the registry would say `image-digest-pinned` while the
        # workflow pulled a tag. The resolved digest has to be the reference
        # the consumer actually names.
        if row["integrity"] == "image-digest-pinned" and IMAGE_DIGEST.match(row["resolved"]):
            for consumer in row["consumers"].split(","):
                consumer = consumer.strip()
                path = ROOT / consumer
                if not consumer or not path.is_file():
                    continue
                if row["resolved"] not in path.read_text(encoding="utf-8"):
                    fail(
                        f"line {line}: {source_id} is recorded as image-digest-pinned "
                        f"at {row['resolved']}, but {consumer} does not name that "
                        f"digest; the consumer is pulling something else"
                    )
                    errors += 1

    return rows, errors


def scan_for_unregistered(
    hosts_by_source: dict[str, set[str]],
    taps_by_source: dict[str, set[str]],
    repositories_by_source: dict[str, set[str]],
) -> int:
    known = set(hosts_by_source)
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

            # Every annotation attached to this construct counts, not just the
            # nearest one, so a construct covered by two sources stays covered
            # -- and so that the checks below see everything that was claimed.
            #
            # Attached means the construct's own line, or the comment block
            # directly above it. The walk stops at the first line of code,
            # because an annotation belongs to the construct it introduces and
            # not to whatever is written under that one: a fixed lookback of a
            # few lines let a download appended below an annotated call inherit
            # its provenance, which is the opposite of what this file means by
            # "proximity is not provenance".
            annotated: set[str] = set()
            # A continued invocation is one construct whichever of its lines
            # matched, and its annotation sits above the first of them, so the
            # walk starts there.
            start = index
            while start > 0 and CONTINUED_LINE.search(lines[start - 1].rstrip()):
                start -= 1
            candidates = list(lines[start:index + 1])
            for cursor in range(start - 1, max(-1, start - 1 - ANNOTATION_LOOKBACK), -1):
                previous = lines[cursor].strip()
                if previous and not COMMENT_LINE.match(previous):
                    break
                candidates.append(lines[cursor])
            for candidate in candidates:
                match = ANNOTATION.search(candidate)
                if match:
                    annotated.update(match.group(1).split(","))

            if not annotated:
                fail(
                    f"{relative}:{index + 1}: unregistered {matched} network source; "
                    f"add it to config/network-sources.tsv and annotate the line "
                    f"with '# network-source: <id>'"
                )
                errors += 1
                continue

            unknown = sorted(
                source_id
                for source_id in annotated
                if source_id not in known and source_id not in RESERVED_ANNOTATIONS
            )
            if unknown:
                for source_id in unknown:
                    fail(f"{relative}:{index + 1}: unknown network-source id {source_id!r}")
                    errors += 1
                continue

            # Proximity is not provenance: an annotation only covers a host it
            # actually names. A construct whose URL is built from a variable
            # names no host here, and is covered by its annotation alone.
            named = literal_hosts(
                construct_text(lines, index), image_reference=matched == "container-image"
            )
            covered: set[str] = set()
            for source_id in annotated:
                if source_id == LOCAL_ONLY:
                    covered |= {host for host in named if host in LOCAL_HOSTS}
                elif source_id != CALLER_PROVIDED:
                    covered |= named & hosts_by_source[source_id]
            for host in sorted(named - covered):
                fail(
                    f"{relative}:{index + 1}: this {matched} downloads from {host}, "
                    f"which no annotated source is served from "
                    f"({', '.join(sorted(annotated))}); annotate it with the source "
                    f"it actually fetches"
                )
                errors += 1

            # The same rule for a tap, which names a repository rather than a
            # host. Without it the annotation on one tap would cover every
            # other tap within the window above, which in a Brewfile is the
            # next few packages.
            if matched in HOMEBREW_TAP_LABELS:
                taps = named_taps(line)
                covered_taps: set[str] = set()
                for source_id in annotated:
                    covered_taps |= taps_by_source.get(source_id, set())
                for tap in sorted(taps - covered_taps):
                    fail(
                        f"{relative}:{index + 1}: this {matched} installs from the "
                        f"Homebrew tap {tap}, which none of the annotated sources is "
                        f"({', '.join(sorted(annotated))}); register "
                        f"https://github.com/{tap.split('/')[0]}/"
                        f"homebrew-{tap.split('/')[1]} in "
                        f"config/network-sources.tsv and annotate the line with it"
                    )
                    errors += 1

            if matched == PACKAGE_REGISTRY_LABEL:
                registries = named_registries(line)
                covered: set[str] = set()
                for source_id in annotated:
                    covered |= repositories_by_source.get(source_id, set())
                for registry in sorted(registries - covered):
                    fail(
                        f"{relative}:{index + 1}: this package registry is "
                        f"github:{registry}, which none of the annotated sources "
                        f"is ({', '.join(sorted(annotated))}); register "
                        f"https://github.com/{registry} in "
                        f"config/network-sources.tsv and annotate the line with it"
                    )
                    errors += 1
    return errors


def main() -> int:
    rows, errors = load_registry()
    if not rows:
        return 1 if errors else 0
    errors += scan_for_unregistered(
        source_hosts(rows), source_taps(rows), source_repositories(rows)
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
