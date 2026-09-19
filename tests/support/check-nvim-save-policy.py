#!/usr/bin/env python3
"""Report the save-time constructs a Neovim Lua configuration registers.

Format-on-save in this configuration belongs to LazyVim: the `vim.g.autoformat`
toggle drives Conform, and nothing else. Three constructs would put a second
policy beside it, outside that toggle:

  * an autocommand on a write event, which runs whatever the toggle says;
  * Conform's own `format_on_save` / `format_after_save` options, which are a
    save hook Conform installs itself;
  * an `autoformat` override, which changes the toggle for some buffers only.

Searching the sources as text cannot tell any of those from a comment that
merely names one -- the trap this repository already walked into in #273. So
the files are lexed as Lua and only code tokens are reported. Anything that
does not tokenise is an error rather than a file quietly contributing nothing.

Output is one TSV record per line:

    scanned\t<count>
    autocmd\t<file>\t<line>\t<comma-separated events, or "dynamic">
    conform-save\t<file>\t<line>\t<option name>
    autoformat\t<file>\t<line>\t<name>

Exit status: 0 when every file was read, 2 when one could not be lexed.
"""

from __future__ import annotations

import sys
from pathlib import Path

KEYWORDS = frozenset(
    """and break do else elseif end false for function goto if in local nil not
    or repeat return then true until while""".split()
)

# The events that make an autocommand a save hook. `BufWriteCmd` replaces the
# write itself, so it belongs here even though it is not a "before" hook.
WRITE_EVENTS = frozenset({"BufWritePre", "BufWrite", "BufWritePost", "BufWriteCmd"})

CONFORM_SAVE_OPTIONS = frozenset({"format_on_save", "format_after_save"})


class LuaSyntaxError(Exception):
    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line
        self.message = message


class Token:
    __slots__ = ("kind", "value", "line")

    def __init__(self, kind: str, value: str, line: int) -> None:
        self.kind = kind
        self.value = value
        self.line = line

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Token({self.kind!r}, {self.value!r}, {self.line})"


def _long_bracket_level(text: str, i: int) -> int | None:
    """Return the level of a long bracket opening at `i`, or None."""
    if text[i] != "[":
        return None
    j = i + 1
    level = 0
    while j < len(text) and text[j] == "=":
        level += 1
        j += 1
    if j < len(text) and text[j] == "[":
        return level
    return None


def _skip_long_bracket(text: str, i: int, level: int, line: int) -> tuple[int, int]:
    """Consume a long bracket body starting at its opening `[`."""
    closing = "]" + "=" * level + "]"
    start = i + 2 + level
    # Lua drops a newline immediately after the opening bracket; only the line
    # count matters here, and counting it either way gives the same total.
    end = text.find(closing, start)
    if end == -1:
        raise LuaSyntaxError(line, "unterminated long bracket")
    line += text.count("\n", i, end)
    return end + len(closing), line


def tokenize(text: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    line = 1
    n = len(text)
    while i < n:
        ch = text[i]

        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r\v\f":
            i += 1
            continue

        # Comments, long and short. A long comment is `--` then a long bracket.
        if text.startswith("--", i):
            level = _long_bracket_level(text, i + 2)
            if level is not None:
                i, line = _skip_long_bracket(text, i + 2, level, line)
                continue
            end = text.find("\n", i)
            i = n if end == -1 else end
            continue

        # Long strings. Short ones fall through to the quote branch below.
        level = _long_bracket_level(text, i)
        if level is not None:
            start_line = line
            i, line = _skip_long_bracket(text, i, level, line)
            tokens.append(Token("string", "", start_line))
            continue

        if ch in "'\"":
            start_line = line
            quote = ch
            i += 1
            chars: list[str] = []
            while True:
                if i >= n:
                    raise LuaSyntaxError(start_line, f"unterminated {quote} string")
                c = text[i]
                if c == "\\":
                    if i + 1 >= n:
                        raise LuaSyntaxError(start_line, "trailing escape in string")
                    if text[i + 1] == "\n":
                        line += 1
                    # The escape's meaning does not matter; only that the next
                    # character cannot close the string.
                    chars.append(text[i + 1])
                    i += 2
                    continue
                if c == "\n":
                    raise LuaSyntaxError(start_line, f"unterminated {quote} string")
                if c == quote:
                    i += 1
                    break
                chars.append(c)
                i += 1
            tokens.append(Token("string", "".join(chars), start_line))
            continue

        if ch.isdigit() or (ch == "." and i + 1 < n and text[i + 1].isdigit()):
            j = i
            if text.startswith(("0x", "0X"), i):
                j += 2
                while j < n and (text[j] in "0123456789abcdefABCDEF.pP" or
                                 (text[j] in "+-" and text[j - 1] in "pP")):
                    j += 1
            else:
                while j < n and (text[j].isdigit() or text[j] in ".eE" or
                                 (text[j] in "+-" and text[j - 1] in "eE")):
                    j += 1
            tokens.append(Token("number", text[i:j], line))
            i = j
            continue

        if ch.isalpha() or ch == "_":
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            tokens.append(Token("keyword" if word in KEYWORDS else "name", word, line))
            i = j
            continue

        for op in ("...", "..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>"):
            if text.startswith(op, i):
                tokens.append(Token("op", op, line))
                i += len(op)
                break
        else:
            tokens.append(Token("op", ch, line))
            i += 1

    return tokens


def _autocmd_events(tokens: list[Token], start: int) -> str:
    """Read the event argument of the `nvim_create_autocmd` call at `start`."""
    i = start + 1
    if i >= len(tokens) or tokens[i].value != "(":
        # Called without parentheses is not valid for this signature; report it
        # rather than guessing, so the caller fails closed.
        return "dynamic"
    i += 1
    if i < len(tokens) and tokens[i].kind == "string":
        return tokens[i].value
    if i < len(tokens) and tokens[i].value == "{":
        events: list[str] = []
        depth = 1
        i += 1
        while i < len(tokens) and depth > 0:
            token = tokens[i]
            if token.value == "{":
                depth += 1
            elif token.value == "}":
                depth -= 1
                if depth == 0:
                    break
            elif token.kind == "string" and depth == 1:
                events.append(token.value)
            elif token.kind == "name" and depth == 1:
                # A name inside the event list is a variable, so the set is not
                # knowable from the source.
                return "dynamic"
            i += 1
        return ",".join(events) if events else "dynamic"
    return "dynamic"


def scan(path: Path, text: str) -> list[tuple[str, int, str]]:
    tokens = tokenize(text)
    found: list[tuple[str, int, str]] = []
    for index, token in enumerate(tokens):
        if token.kind != "name":
            continue
        if token.value == "nvim_create_autocmd":
            found.append(("autocmd", token.line, _autocmd_events(tokens, index)))
        elif token.value in CONFORM_SAVE_OPTIONS:
            found.append(("conform-save", token.line, token.value))
        elif token.value == "autoformat":
            found.append(("autoformat", token.line, token.value))
    return found


def main(argv: list[str]) -> int:
    roots = [Path(arg) for arg in argv[1:]]
    if not roots:
        print("usage: check-nvim-save-policy.py <lua-root>...", file=sys.stderr)
        return 2

    files: list[Path] = []
    for root in roots:
        if root.is_dir():
            files.extend(sorted(root.rglob("*.lua")))
        elif root.suffix == ".lua":
            files.append(root)

    records: list[str] = []
    status = 0
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            print(f"cannot read {path}: {error}", file=sys.stderr)
            status = 2
            continue
        try:
            hits = scan(path, text)
        except LuaSyntaxError as error:
            print(f"cannot read as Lua: {path}:{error.line}: {error.message}",
                  file=sys.stderr)
            status = 2
            continue
        for kind, line, detail in hits:
            records.append(f"{kind}\t{path}\t{line}\t{detail}")

    print(f"scanned\t{len(files)}")
    for record in records:
        print(record)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
