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

What counts as a use
--------------------
Code, not text. This read the library as one string and matched each symbol
name anywhere in it, so a library whose only mention of `die` and `warn` was
ordinary English prose in a comment -- "callers should die rather than
continue", "the installer will warn about it first" -- was told to add a guard
for functions it never calls. Six of the libraries in this tree mention a
`common.sh` function in a comment and nowhere else.

So the two halves are read differently, because they are different questions:

* **A function is used when the library runs it.** `scripts/lib/shell.py`
  answers that with `commands()`, which reads command position and drops
  comments and single-quoted text on the way. Every call site counts, whether
  or not anything in this file reaches it: a library function is called by its
  consumers, so reachability from load-time code would be the wrong test.
* **A variable is used when the library reads it undefaulted.** That one needs
  comments gone and strings kept, since `"$DOTFILES_ROOT/config"` is a real
  read, so it goes through `code_line`/`code_text` instead.

The guard and the sibling edges are read as code too, so a commented-out
`source` no longer satisfies either.

Usage:
    scripts/validate-library-guards.py [--root DIR]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from shell import code_text, commands, shell_functions  # noqa: E402

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
# Variables `common.sh` assigns at the top level and the rest of the tree reads.
COMMON_VARIABLES = re.compile(
    r"^(?P<name>DOTFILES_ROOT|XDG_[A-Z_]+)=", re.MULTILINE
)


def fail(message: str) -> None:
    print(f"library guards: {message}", file=sys.stderr)


def common_symbols(library_dir: pathlib.Path) -> set[str]:
    """Every function and top-level variable `common.sh` defines."""
    text = (library_dir / COMMON).read_text(encoding="utf-8")
    symbols = set(shell_functions(text))
    symbols |= {
        match.group("name") for match in COMMON_VARIABLES.finditer(code_text(text))
    }
    symbols.discard("DOTFILES_COMMON_LOADED")
    return symbols


def used_symbols(text: str, symbols: set[str], own: set[str]) -> set[str]:
    """The `common.sh` symbols a library depends on and does not define itself.

    A library that defines its own `warn` is using that one, not `common.sh`'s,
    so redefinition is treated as ownership rather than as a use.

    A variable read with its own default -- `${XDG_STATE_HOME:-$HOME/...}` --
    is not a dependency: it is correct whether or not `common.sh` ran, which is
    the whole point of writing it that way. Only an undefaulted read counts.
    Functions have no such form, so every call to one counts.
    """
    wanted = symbols - own
    # Called, rather than merely named. A function's name in a comment or in a
    # single-quoted string is not a call, and this is what used to say it was.
    used = {symbol for symbol in wanted if symbol in commands(text)}

    # A variable's value lives in a string more often than not, so this half
    # keeps the strings and drops only the comments.
    code = code_text(text)
    for symbol in wanted:
        if not symbol.isupper():
            continue
        pattern = rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])"
        # `${NAME` followed by any of the parameter-expansion default or
        # alternate operators is a defaulted read; anything else is not.
        defaulted = rf"\$\{{{re.escape(symbol)}(?::?[-=+?])"
        occurrences = len(re.findall(pattern, code))
        if not occurrences:
            continue
        if occurrences == len(re.findall(defaulted, code)):
            continue
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
    # As code: a guard block that has been commented out sources nothing, and
    # neither does a commented sibling `source` line.
    code = code_text(text)
    if GUARD.search(code):
        return True
    return any(
        reaches_common(match.group("name"), texts, seen)
        for match in SOURCES.finditer(code)
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
        own = set(shell_functions(text))
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
