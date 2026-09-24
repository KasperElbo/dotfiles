#!/usr/bin/env python3
"""Mechanical documentation checks.

Prose cannot be verified, but six kinds of documentation rot can be, and all
six are the kinds that quietly make a document wrong:

1. **Broken internal links.** Every relative link between tracked Markdown
   files must resolve, and a link with an anchor must name a heading that
   exists in the target.
2. **Dangling plain-text references.** A quoted phrase used as a pseudo-link
   (`see "Optional Sway session" below`) must name a heading that actually
   exists somewhere under `docs/`, the same way a real Markdown link must
   resolve. This is what a documentation split leaves behind when a section
   moves or is renamed but the plain-text pointer to it is not updated.
3. **Orphan documents.** Every document under `docs/` must be reachable from
   the README or the documentation index, so splitting a page cannot leave a
   section that nothing points at.
4. **Stale issue claims.** A support contract must describe this checkout, not
   a plan. Documentation may not say a capability is waiting for, blocked on,
   or arriving with an issue.
5. **Invalid platform-support claims.** An `./install.sh --platform X` command
   line in documentation may only pass options that platform's manifest
   declares. This is what stops a guide from advertising a Fedora-only flag on
   macOS. The same holds for an installer command line that names no
   platform: `./install.sh --flag` must pass a flag some platform declares,
   and `platforms/<name>/install.sh --flag` one that platform declares, each
   besides the transient controls that entry point accepts. A renamed flag is
   the likeliest single cause of rot here, and before this a command without
   `--platform` was not read at all (#539, V5-04). Only installer command
   lines are read: most backticked `--flag`s in the corpus belong to git, dnf
   or brew, and measured against the tree this reads 93 root and 14 platform
   command lines with nothing to report.
6. **Unknown capability names.** A backticked word written directly before or
   after the word "capability" names a capability, so it must be a row of
   `config/capabilities.tsv`.

Generated documents are checked by their own renderers (`--check`), which
`./scripts/lint.sh` runs alongside this.

Usage:
    scripts/validate-docs.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import read_tsv  # noqa: E402

LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(\s*(?P<target>[^)\s]+?)\s*\)")
HEADING = re.compile(r"^(#{1,6})\s+(?P<title>.+?)\s*#*$")
FENCE = re.compile(r"^\s*```")

# A quoted phrase used as a pseudo-link to a heading, e.g. `see "Optional
# Sway session" below`. Markdown links are checked for real anchors above;
# this catches the plain-text convention the documentation split left behind
# in places, pointing at a heading that no longer exists anywhere.
DANGLING_REFERENCE = re.compile(r'"(?P<phrase>[^"]{3,80})"\s+(?:above|below)\b')

STALE_CLAIM = re.compile(
    r"(waiting (?:for|on) (?:issue )?#\d+"
    r"|blocked (?:by|on|until) (?:issue )?#\d+"
    r"|TODO once (?:issue )?#?\d+"
    r"|once (?:issue )?#\d+ (?:lands|ships|merges)"
    r"|(?:will be|to be) (?:added|implemented|supported) (?:in|by) (?:issue )?#\d+"
    r"|not (?:yet )?implemented here)",
    re.IGNORECASE,
)

INSTALL_COMMAND = re.compile(r"\./install\.sh\b[^\n]*")
# Any installer command line, up to the end of its code span or a comment: the
# root entry point, or one platform's installer run directly.
INSTALLER_LINE = re.compile(
    r"(?:(?<![\w/.-])\./install\.sh|(?<![\w.-])(?:\./)?platforms/(?P<platform>[a-z-]+)/install\.sh)"
    r"\b(?P<arguments>[^\n`#]*)"
)
CAPABILITY_NAME = re.compile(
    r"`(?P<before>[A-Za-z0-9_.:/-]+)`\s+capabilit(?:y|ies)\b"
    r"|\bcapabilit(?:y|ies)\s+`(?P<after>[A-Za-z0-9_.:/-]+)`",
    re.IGNORECASE,
)
PLATFORM_ARGUMENT = re.compile(r"--platform[ =]([a-z-]+)")
OPTION_ARGUMENT = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")

# Controls that belong to one invocation and therefore have no manifest row.
# The root installer owns these four and every platform accepts them.
TRANSIENT_FLAGS = {
    "--platform",
    "--rerun",
    "--dry-run",
    "--non-interactive",
    "--help",
}

# The rest are not universal, so advertising one against the wrong platform is
# as wrong as advertising an option that does not exist. Each entry is what
# that platform's own parser accepts: the CTF guest rejects --dev-workflows
# outright (platforms/parrot-ctf/install.sh), and the deprecated spellings live
# only where they were released.
PLATFORM_TRANSIENT_FLAGS = {
    "fedora": {"--dev-workflows", "--no-dev-workflows"},
    "fedora-wsl": {"--dev-workflows", "--no-dev-workflows", "--smoke-test"},
    "macos": {"--dev-workflows", "--no-dev-workflows", "--workflows", "--no-workflows"},
    "parrot-ctf": set(),
}


def slug(title: str) -> str:
    title = title.strip().lower()
    title = title.replace("`", "")
    title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title)
    title = re.sub(r"[^\w\- ]", "", title)
    return title.replace(" ", "-")


def tracked_markdown(root: pathlib.Path) -> list[pathlib.Path]:
    try:
        listing = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--", "*.md"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        names = [name for name in listing.split("\0") if name]
    except (OSError, subprocess.CalledProcessError):
        names = [str(path.relative_to(root)) for path in root.rglob("*.md")]
    return [root / name for name in names]


def anchors(path: pathlib.Path) -> set[str]:
    found: set[str] = set()
    fence = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if FENCE.match(line):
            fence = not fence
            continue
        if fence:
            continue
        match = HEADING.match(line)
        if match:
            found.add(slug(match.group("title")))
    return found


def outside_fences(path: pathlib.Path) -> list[tuple[int, str]]:
    result = []
    fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if FENCE.match(line):
            fence = not fence
            continue
        if not fence:
            result.append((number, line))
    return result


def check_links(root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]) -> None:
    anchor_cache: dict[pathlib.Path, set[str]] = {}
    for document in documents:
        relative = document.relative_to(root)
        for number, line in outside_fences(document):
            for match in LINK.finditer(line):
                target = match.group("target")
                if target.startswith(("http://", "https://", "mailto:", "<")):
                    continue
                path_part, _, anchor = target.partition("#")
                if not path_part:
                    resolved = document
                else:
                    resolved = (document.parent / path_part).resolve()
                    if not resolved.exists():
                        problems.append(f"{relative}:{number}: broken link: {target}")
                        continue
                if anchor and resolved.suffix == ".md":
                    if resolved not in anchor_cache:
                        anchor_cache[resolved] = anchors(resolved)
                    if anchor not in anchor_cache[resolved]:
                        problems.append(
                            f"{relative}:{number}: link anchor does not exist: {target}"
                        )


def check_dangling_references(
    root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]
) -> None:
    all_titles: list[str] = []
    for document in documents:
        for _, line in outside_fences(document):
            match = HEADING.match(line)
            if match:
                all_titles.append(match.group("title").strip().lower())

    for document in documents:
        relative = document.relative_to(root)
        for number, line in outside_fences(document):
            for match in DANGLING_REFERENCE.finditer(line):
                phrase = match.group("phrase").strip().lower()
                if any(phrase in title for title in all_titles):
                    continue
                problems.append(
                    f"{relative}:{number}: dangling plain-text reference "
                    f'{match.group(0)!r}; no heading anywhere under docs/ '
                    "contains that phrase — convert it to a relative link"
                )


def outbound_links(document: pathlib.Path) -> set[pathlib.Path]:
    """The Markdown documents this one links to, resolved."""
    targets: set[pathlib.Path] = set()
    for _, line in outside_fences(document):
        for match in LINK.finditer(line):
            target = match.group("target").partition("#")[0]
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue
            resolved = (document.parent / target).resolve()
            if resolved.suffix == ".md":
                targets.add(resolved)
    return targets


def check_orphans(root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]) -> None:
    """Every document under docs/ must be *reachable* from an entry point.

    Counting inbound links instead asks a weaker question than the rule states.
    Two pages that link to each other satisfy "something links to me" while
    nothing in either README points into the pair, which is the exact shape a
    documentation split produces: a new sub-index, its children linking back to
    it, and the sub-index never added to docs/README.md.

    So this walks outward from the entry points rather than collecting every
    link in the tree, and a document the walk never arrives at is an orphan
    however many siblings point at it.
    """
    entry_points = [root / "README.md", root / "docs" / "README.md"]
    known = {document.resolve() for document in documents}
    reached: set[pathlib.Path] = set()
    frontier = [point.resolve() for point in entry_points if point.exists()]
    while frontier:
        document = frontier.pop()
        if document in reached:
            continue
        reached.add(document)
        for target in outbound_links(document):
            # Only documents this validator knows about can be walked further;
            # a link outside the tracked set is checked by check_links.
            if target in known and target not in reached:
                frontier.append(target)
    for document in documents:
        resolved = document.resolve()
        if resolved in (point.resolve() for point in entry_points):
            continue
        if not resolved.is_relative_to((root / "docs").resolve()):
            continue
        if resolved not in reached:
            problems.append(
                f"{document.relative_to(root)}: nothing reachable from README.md "
                "or docs/README.md links to this document; add it to "
                "docs/README.md or the guide it belongs to"
            )


def check_stale_claims(root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]) -> None:
    for document in documents:
        relative = document.relative_to(root)
        # Rationale and history may discuss issues; the support contract may not.
        if relative.parts[:2] == ("docs", "architecture"):
            continue
        if relative.name in {"testing.md", "capabilities.md"}:
            continue
        for number, line in outside_fences(document):
            match = STALE_CLAIM.search(line)
            if match:
                problems.append(
                    f"{relative}:{number}: documentation states a capability as pending "
                    f"({match.group(0)!r}); describe what this checkout does instead"
                )


def check_platform_options(root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]) -> None:
    manifest = root / "config" / "install-options.tsv"
    if not manifest.exists():
        return
    rows = read_tsv(manifest)
    declared: dict[str, set[str]] = {}
    for row in rows:
        flags = declared.setdefault(row["platform"], set())
        for column in ("on_flag", "off_flag"):
            if row[column] not in {"", "-"}:
                flags.add(row[column])

    for document in documents:
        relative = document.relative_to(root)
        text = document.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            for command in INSTALL_COMMAND.findall(line):
                platform_match = PLATFORM_ARGUMENT.search(command)
                if not platform_match:
                    continue
                platform = platform_match.group(1)
                if platform not in declared:
                    problems.append(
                        f"{relative}:{number}: unknown platform in an install command: {platform}"
                    )
                    continue
                for flag in OPTION_ARGUMENT.findall(command):
                    if (
                        flag in TRANSIENT_FLAGS
                        or flag in PLATFORM_TRANSIENT_FLAGS.get(platform, set())
                        or flag in declared[platform]
                    ):
                        continue
                    problems.append(
                        f"{relative}:{number}: `{flag}` is not an option of "
                        f"--platform {platform}: {command.strip()}"
                    )


def check_installer_lines(
    root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]
) -> None:
    """Flags on installer command lines that name no platform (item 5)."""
    manifest = root / "config" / "install-options.tsv"
    if not manifest.exists():
        return
    declared: dict[str, set[str]] = {}
    for row in read_tsv(manifest):
        flags = declared.setdefault(row["platform"], set())
        for column in ("on_flag", "off_flag"):
            if row[column] not in {"", "-"}:
                flags.add(row[column])
    # The root installer resolves the platform itself, so any platform's
    # options and transient controls may follow it; `--platform` lines are
    # check_platform_options' and are held to that one platform.
    root_accepts = set().union(*declared.values(), TRANSIENT_FLAGS, *PLATFORM_TRANSIENT_FLAGS.values())
    # A platform installer run directly has no --platform to take, and --rerun
    # belongs to the root installer (platforms/parrot-ctf/install.sh says so).
    direct_transients = TRANSIENT_FLAGS - {"--platform", "--rerun"}

    for document in documents:
        relative = document.relative_to(root)
        for number, line in every_line(document):
            for command in INSTALLER_LINE.finditer(line):
                arguments = command.group("arguments")
                platform = command.group("platform")
                if platform is None and PLATFORM_ARGUMENT.search(arguments):
                    continue
                if platform is None:
                    accepted, where = root_accepts, "./install.sh on any platform"
                elif platform not in declared:
                    problems.append(
                        f"{relative}:{number}: unknown platform installer: platforms/{platform}/install.sh"
                    )
                    continue
                else:
                    accepted = declared[platform] | direct_transients | PLATFORM_TRANSIENT_FLAGS.get(platform, set())
                    where = f"platforms/{platform}/install.sh"
                for flag in OPTION_ARGUMENT.findall(arguments):
                    if flag not in accepted:
                        problems.append(
                            f"{relative}:{number}: `{flag}` is not an option of {where} "
                            f"(config/install-options.tsv): {command.group(0).strip()}"
                        )


def every_line(document: pathlib.Path) -> list[tuple[int, str]]:
    """Every line, fenced or not: a command in a code block is still advertised."""
    return list(enumerate(document.read_text(encoding="utf-8").splitlines(), 1))


def check_capability_names(
    root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]
) -> None:
    manifest = root / "config" / "capabilities.tsv"
    if not manifest.exists():
        return
    known = {row["capability"] for row in read_tsv(manifest)}
    for document in documents:
        relative = document.relative_to(root)
        for number, line in outside_fences(document):
            for match in CAPABILITY_NAME.finditer(line):
                name = match.group("before") or match.group("after")
                if name not in known:
                    problems.append(
                        f"{relative}:{number}: `{name}` is written as a capability, but "
                        f"config/capabilities.tsv has no such capability"
                    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    documents = [path for path in tracked_markdown(root) if path.exists()]
    problems: list[str] = []
    check_links(root, documents, problems)
    check_dangling_references(root, documents, problems)
    check_orphans(root, documents, problems)
    check_stale_claims(root, documents, problems)
    check_platform_options(root, documents, problems)
    check_installer_lines(root, documents, problems)
    check_capability_names(root, documents, problems)

    for problem in problems:
        print(f"Documentation: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
