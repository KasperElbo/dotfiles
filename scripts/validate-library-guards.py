#!/usr/bin/env python3
"""Every shared library that uses `common.sh` must source it itself.

`common/lib/common.sh` defines `DOTFILES_ROOT`, the XDG variables and the
helper functions the rest of `common/lib/` is written against. A library that
uses one of those without sourcing `common.sh` is correct only by accident --
it works because every caller today happens to have sourced `common.sh` first,
and it fails the moment one does not.

That failure is silent rather than loud, which is why it is checked here. An
undefined function inside a test expression evaluates false, so a standalone
`preflight.sh` once reported a command that was present as missing: it was
calling a `command_exists` that did not exist, and got a plausible-looking
answer instead of an error.

The convention is therefore the guard, as `common.sh` itself establishes it:

    if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
      # shellcheck source=common.sh
      source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
    fi

The guard, and not a bare `source`, because a second source would reset a
`DOTFILES_ROOT` or XDG value the caller had adjusted.

A library may instead source a sibling that is itself guarded; that reaches
`common.sh` just as surely, so this follows those edges rather than demanding
every file repeat the block.

Usage:
    scripts/validate-library-guards.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

LIBRARY_DIR = pathlib.Path("common") / "lib"
COMMON = "common.sh"
GUARD = re.compile(
    r'if \[\[ -z "\$\{DOTFILES_COMMON_LOADED:-\}" \]\]; then\s*\n'
    r"(?:\s*#[^\n]*\n)*"
    r'\s*source "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/common\.sh"\s*\n'
    r"\s*fi",
    re.MULTILINE,
)
# `source "$(dirname "${BASH_SOURCE[0]}")/<name>.sh"`, guarded or not.
SOURCES = re.compile(
    r'source "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/(?P<name>[A-Za-z0-9_-]+\.sh)"'
)
# A `name() {` definition at the start of a line, which is how every function in
# these libraries is written.
DEFINITION = re.compile(r"^(?P<name>[A-Za-z_][A-Za-z0-9_]*)\(\)", re.MULTILINE)
# Variables `common.sh` assigns at the top level and the rest of the tree reads.
COMMON_VARIABLES = re.compile(
    r"^(?P<name>DOTFILES_ROOT|XDG_[A-Z_]+)=", re.MULTILINE
)


def fail(message: str) -> None:
    print(f"library guards: {message}", file=sys.stderr)


def common_symbols(library_dir: pathlib.Path) -> set[str]:
    """Every function and top-level variable `common.sh` defines."""
    text = (library_dir / COMMON).read_text(encoding="utf-8")
    symbols = {match.group("name") for match in DEFINITION.finditer(text)}
    symbols |= {match.group("name") for match in COMMON_VARIABLES.finditer(text)}
    symbols.discard("DOTFILES_COMMON_LOADED")
    return symbols


def used_symbols(text: str, symbols: set[str], own: set[str]) -> set[str]:
    """The `common.sh` symbols a library depends on and does not define itself.

    A library that defines its own `warn` is using that one, not `common.sh`'s,
    so redefinition is treated as ownership rather than as a use.

    A variable read with its own default -- `${XDG_STATE_HOME:-$HOME/...}` --
    is not a dependency: it is correct whether or not `common.sh` ran, which is
    the whole point of writing it that way. Only an undefaulted read counts.
    Functions have no such form, so every reference to one counts.
    """
    used = set()
    for symbol in symbols - own:
        pattern = rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])"
        if symbol.isupper():
            # `${NAME` followed by any of the parameter-expansion default or
            # alternate operators is a defaulted read; anything else is not.
            defaulted = rf"\$\{{{re.escape(symbol)}(?::?[-=+?])"
            occurrences = len(re.findall(pattern, text))
            if occurrences and occurrences == len(re.findall(defaulted, text)):
                continue
        if re.search(pattern, text):
            used.add(symbol)
    return used


def reaches_common(
    name: str, texts: dict[str, str], seen: set[str] | None = None
) -> bool:
    """Whether sourcing this library reaches a guarded `common.sh` source.

    Following the sibling edges is what lets a library source one guarded
    neighbour instead of repeating the block, which several already do.
    """
    seen = seen if seen is not None else set()
    if name in seen:
        return False
    seen.add(name)
    text = texts.get(name)
    if text is None:
        return False
    if GUARD.search(text):
        return True
    return any(
        reaches_common(match.group("name"), texts, seen)
        for match in SOURCES.finditer(text)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1]
    )
    arguments = parser.parse_args()
    library_dir = arguments.root.resolve() / LIBRARY_DIR

    if not library_dir.is_dir():
        fail(f"no shared library directory at {library_dir}")
        return 1

    texts = {
        path.name: path.read_text(encoding="utf-8")
        for path in sorted(library_dir.glob("*.sh"))
    }
    if COMMON not in texts:
        fail(f"{LIBRARY_DIR / COMMON} is missing")
        return 1

    symbols = common_symbols(library_dir)
    if not symbols:
        fail(f"{LIBRARY_DIR / COMMON} defines nothing; the check would pass vacuously")
        return 1

    errors = 0
    for name, text in texts.items():
        if name == COMMON:
            continue
        own = {match.group("name") for match in DEFINITION.finditer(text)}
        used = used_symbols(text, symbols, own)
        if not used:
            continue
        if reaches_common(name, texts):
            continue
        fail(
            f"{LIBRARY_DIR / name} uses {', '.join(sorted(used))} from "
            f"{COMMON} but never sources it. Add the guard so the library is "
            f"correct when sourced standalone:\n"
            f'    if [[ -z "${{DOTFILES_COMMON_LOADED:-}}" ]]; then\n'
            f"      # shellcheck source={COMMON}\n"
            f'      source "$(dirname "${{BASH_SOURCE[0]}}")/{COMMON}"\n'
            f"    fi"
        )
        errors += 1

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
