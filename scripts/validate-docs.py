#!/usr/bin/env python3
"""Mechanical documentation checks.

Prose cannot be verified, but four kinds of documentation rot can be, and all
four are the kinds that quietly make a document wrong:

1. **Broken internal links.** Every relative link between tracked Markdown
   files must resolve, and a link with an anchor must name a heading that
   exists in the target.
2. **Orphan documents.** Every document under `docs/` must be reachable from
   the README or the documentation index, so splitting a page cannot leave a
   section that nothing points at.
3. **Stale issue claims.** A support contract must describe this checkout, not
   a plan. Documentation may not say a capability is waiting for, blocked on,
   or arriving with an issue.
4. **Invalid platform-support claims.** An `./install.sh --platform X` command
   line in documentation may only pass options that platform's manifest
   declares. This is what stops a guide from advertising a Fedora-only flag on
   macOS.

Generated documents are checked by their own renderers (`--check`), which
`./scripts/lint.sh` runs alongside this.

Usage:
    scripts/validate-docs.py [--root DIR]
"""

from __future__ import annotations

import argparse
import csv
import pathlib
import re
import subprocess
import sys

LINK = re.compile(r"(?<!\!)\[[^\]]*\]\(\s*(?P<target>[^)\s]+?)\s*\)")
HEADING = re.compile(r"^(#{1,6})\s+(?P<title>.+?)\s*#*$")
FENCE = re.compile(r"^\s*```")

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
PLATFORM_ARGUMENT = re.compile(r"--platform[ =]([a-z-]+)")
OPTION_ARGUMENT = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")

# Controls that belong to one invocation and therefore have no manifest row.
TRANSIENT_FLAGS = {
    "--platform",
    "--rerun",
    "--dry-run",
    "--non-interactive",
    "--dev-workflows",
    "--smoke-test",
    "--help",
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


def check_orphans(root: pathlib.Path, documents: list[pathlib.Path], problems: list[str]) -> None:
    entry_points = [root / "README.md", root / "docs" / "README.md"]
    linked: set[pathlib.Path] = set()
    for document in documents:
        for _, line in outside_fences(document):
            for match in LINK.finditer(line):
                target = match.group("target").partition("#")[0]
                if not target or target.startswith(("http://", "https://", "mailto:")):
                    continue
                resolved = (document.parent / target).resolve()
                if resolved.suffix == ".md":
                    linked.add(resolved)
    for document in documents:
        if document in (point.resolve() for point in entry_points):
            continue
        if not document.resolve().is_relative_to((root / "docs").resolve()):
            continue
        if document.resolve() not in linked:
            problems.append(
                f"{document.relative_to(root)}: nothing links to this document; "
                "add it to docs/README.md or the guide it belongs to"
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
    with manifest.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
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
                    if flag in TRANSIENT_FLAGS or flag in declared[platform]:
                        continue
                    problems.append(
                        f"{relative}:{number}: `{flag}` is not an option of "
                        f"--platform {platform}: {command.strip()}"
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
    check_orphans(root, documents, problems)
    check_stale_claims(root, documents, problems)
    check_platform_options(root, documents, problems)

    for problem in problems:
        print(f"Documentation: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
