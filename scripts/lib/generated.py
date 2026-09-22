#!/usr/bin/env python3
r"""The one comparison every `render --check` gate makes.

Each of the eight renderers used to repeat the same five lines: read the
committed file, compare it against the freshly rendered string, print a stale
message or write the file. Repeating the comparison meant repeating its rule,
and the rule was wrong in all eight copies in the same way.

`pathlib.Path.read_text()` opens in text mode with `newline=None`, which is
Python's universal-newline translation: `\r\n` and a lone `\r` both arrive as
`\n`. A gate comparing that view is comparing a normalised *reading* of the
file rather than its bytes, so a document whose committed bytes differ from a
fresh render was reported as current. `git diff --check` catches CRLF over a
pull request's range, but nothing catches a bare `\r` in the middle of a file,
and `./scripts/lint.sh` has no whitespace check of its own.

So the comparison here is on bytes, and the write is `write_bytes`, which is
also the only way `\n` survives a run on a platform whose text mode would
translate it back. `.gitattributes` normalises line endings at the source; this
is the gate that notices when something got past it.

`check_or_write` is the whole interface. A renderer builds its content and
hands it over with the message a contributor should see, so the gates cannot
drift apart again.
"""

from __future__ import annotations

import pathlib
import sys
from collections.abc import Sequence


def read_committed(path: pathlib.Path) -> str:
    """Decode a tracked file without translating its line endings.

    The partial renderers splice generated content into a page that also holds
    hand-written prose, so they have to read the file before they can render.
    Reading it this way keeps the bytes outside the generated region exactly as
    they are, which is what makes the comparison in `check_or_write` exact for
    those renderers too.
    """
    return path.read_bytes().decode("utf-8")


def check_or_write(
    target: pathlib.Path,
    content: str,
    argv: Sequence[str],
    *,
    stale: str,
    remedy: str,
) -> int:
    """Compare or write `content`, returning the exit status the caller owes.

    With `--check` in `argv` this is the drift gate: the committed bytes must
    be exactly what a fresh render produces. Without it, the file is written.
    """
    encoded = content.encode("utf-8")
    if "--check" in argv:
        if not target.exists() or target.read_bytes() != encoded:
            print(f"{stale}: {target}", file=sys.stderr)
            print(f"Run {remedy}", file=sys.stderr)
            return 1
        return 0
    target.write_bytes(encoded)
    return 0
