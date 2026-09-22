#!/usr/bin/env python3
"""The tracked shell files `./scripts/lint.sh` is responsible for.

The lint gate used to derive its own file set from `git ls-files -- '*.sh'`.
That rule decides scope by filename extension, and a command installed onto
PATH does not carry one: `bin/.local/bin/theme`, `doctor`, the stowed Sway and
WSL interop commands and `platforms/fedora/assets/dotfiles-sway` -- the Wayland
session `Exec=`, which the display manager runs to start the desktop -- all
carry a Bash shebang, and none of them was ever syntax-checked or ShellChecked.
A hard syntax error could be appended to `bin/.local/bin/theme` and the gate
still printed "Shell validation passed".

The set is computed here, once, and read by the lint entry point, so there is
one definition of "a shell file this repository lints" rather than a glob in a
shell script that nothing checks. `scripts/validate-shell-file-roles.py` shares
the same shebang predicate for the files whose mode it governs.

Output is NUL-separated by default, because a `git ls-files -z` reader is what
replaced it and the caller should not have to care whether a path can contain a
newline.

Usage:
    scripts/list-shell-files.py [--root DIR] [--print0 | --lines]
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from manifests import shell_files  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    separator = parser.add_mutually_exclusive_group()
    separator.add_argument(
        "--print0", dest="separator", action="store_const", const="\0", default="\0"
    )
    separator.add_argument(
        "--lines", dest="separator", action="store_const", const="\n"
    )
    arguments = parser.parse_args()
    root = arguments.root.resolve()

    names = shell_files(root)

    # A floor, so a regression in the reader cannot silently shrink coverage
    # back to something narrower than the glob it replaced. The old rule is
    # cheap to re-derive and its result must remain a subset of this one.
    extension_glob = {name for name in names if name.endswith(".sh")}
    missing = sorted(
        name
        for name in _tracked_extension_files(root)
        if name not in extension_glob
    )
    if missing:
        print(
            "list-shell-files: the reader dropped tracked .sh files that the "
            "extension glob it replaced would have linted: " + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    if not names:
        print("list-shell-files: no tracked shell files found.", file=sys.stderr)
        return 1

    sys.stdout.write(arguments.separator.join(names) + arguments.separator)
    return 0


def _tracked_extension_files(root: pathlib.Path) -> list[str]:
    """The set the lint gate used to use, for the floor check above."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.sh"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"list-shell-files: cannot list tracked files in {root}: "
            f"{result.stderr.strip() or f'git exited {result.returncode}'}"
        )
    return [name for name in result.stdout.split("\0") if name]


if __name__ == "__main__":
    raise SystemExit(main())
