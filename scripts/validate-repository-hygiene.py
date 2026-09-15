#!/usr/bin/env python3
"""Repository hygiene checks that are cheap, deterministic, and easy to read.

Three unrelated kinds of rot are caught here, all of which are invisible in a
diff and expensive to notice later:

1. A lone root npm lockfile. A `package-lock.json` with no root `package.json`
   is an accident: it makes dependency tooling and supply-chain scanners
   believe this repository is an npm project when nothing here runs npm.
2. A retained upstream licence text that nothing points at, or a third-party
   notice that points at a path which no longer exists.
3. A licensing page whose stated decision disagrees with what is actually in
   the repository. The check never demands that a licence be chosen: an
   undecided repository is valid. It only requires that the page and the tree
   say the same thing.

Usage:
    scripts/validate-repository-hygiene.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

NPM_LOCKFILES = ("package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml")
LICENSE_FILENAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING")
NOTICES = pathlib.Path("docs/reference/third-party-notices.md")
LICENSING = pathlib.Path("docs/reference/licensing.md")
LICENSE_TEXT_DIR = pathlib.Path("LICENSES")

STATUS_UNDECIDED = re.compile(r"^\*\*Status: undecided\b", re.MULTILINE)
STATUS_DECIDED = re.compile(r"^\*\*Status: decided — (?P<license>[^.*]+)\.\*\*", re.MULTILINE)
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\((?P<target>[^)#\s]+)(?:#[^)\s]*)?\)")
INLINE_PATH = re.compile(r"`(?P<path>[A-Za-z0-9_.][A-Za-z0-9_./-]*/[A-Za-z0-9_./-]*)`")


def check_npm_lockfiles(root: pathlib.Path, problems: list[str]) -> None:
    manifest = root / "package.json"
    for name in NPM_LOCKFILES:
        lockfile = root / name
        if not lockfile.exists():
            continue
        if manifest.exists():
            continue
        problems.append(
            f"{name} exists at the repository root without a root package.json. "
            "This repository has no root npm project; remove the lockfile, or add "
            "the manifest, scripts and documentation that make it meaningful."
        )


def check_third_party_notices(root: pathlib.Path, problems: list[str]) -> None:
    notices = root / NOTICES
    if not notices.exists():
        problems.append(f"missing third-party notice index: {NOTICES}")
        return

    text = notices.read_text(encoding="utf-8")

    license_dir = root / LICENSE_TEXT_DIR
    retained = sorted(path.name for path in license_dir.iterdir()) if license_dir.is_dir() else []
    for name in retained:
        if f"{LICENSE_TEXT_DIR.as_posix()}/{name}" not in text:
            problems.append(
                f"{LICENSE_TEXT_DIR / name} is retained but not referenced by {NOTICES}"
            )

    for match in MARKDOWN_LINK.finditer(text):
        target = match.group("target")
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        resolved = (notices.parent / target).resolve()
        if not resolved.exists():
            problems.append(f"{NOTICES} links to a path that does not exist: {target}")

    for match in INLINE_PATH.finditer(text):
        candidate = match.group("path")
        if not (root / candidate).exists():
            problems.append(
                f"{NOTICES} names a repository path that does not exist: {candidate}"
            )


def check_license_decision(root: pathlib.Path, problems: list[str]) -> None:
    licensing = root / LICENSING
    if not licensing.exists():
        problems.append(f"missing licensing decision page: {LICENSING}")
        return

    text = licensing.read_text(encoding="utf-8")
    present = [name for name in LICENSE_FILENAMES if (root / name).exists()]
    decided = STATUS_DECIDED.search(text)
    undecided = STATUS_UNDECIDED.search(text)

    if not decided and not undecided:
        problems.append(
            f"{LICENSING} must open with either '**Status: undecided' or "
            "'**Status: decided — <licence>.**' so the repository's licence state is explicit."
        )
        return

    if decided and not present:
        problems.append(
            f"{LICENSING} records the licence decision "
            f"'{decided.group('license').strip()}', but no root licence file "
            f"({', '.join(LICENSE_FILENAMES)}) exists."
        )
    if undecided and present:
        problems.append(
            f"a root licence file exists ({', '.join(present)}) but {LICENSING} still "
            "records the decision as undecided; record the chosen licence there."
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
        help="repository root to check (default: this repository)",
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    problems: list[str] = []
    check_npm_lockfiles(root, problems)
    check_third_party_notices(root, problems)
    check_license_decision(root, problems)

    for problem in problems:
        print(f"Repository hygiene: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
