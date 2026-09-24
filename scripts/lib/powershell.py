"""Read PowerShell with its comments dropped, line for line.

The shell suites assert a great deal about the Windows scripts by looking for
a call or a parameter in their text, and a raw search cannot tell a call from
a comment naming it: replacing `Invoke-ElevatedWslUpdate` with
`# Invoke-ElevatedWslUpdate runs later` passed every such assertion (issue
#537). ``shell.code_text`` answers that for shell; PowerShell comments differ
enough -- ``<# ... #>`` blocks, backtick escapes, here-strings -- to need their
own reader, and this is it.

Like ``shell.code_text`` it drops comments and nothing else: strings keep
their text, because a message the script prints or a path it joins is code
the assertion means, and every line keeps its number, so ``grep -n`` over the
result still points at the source. It is a reader for this repository's
PowerShell, not a parser, and it is loud where it cannot read: text that ends
inside a string or a block comment raises ``UnreadablePowerShell``.
"""

from __future__ import annotations

# A `#` opens a comment only where a token starts: at the start of a line,
# after whitespace, or after a character that ends the token before it.
# `a#b` is one bareword, and `$x#` would be the same.
_COMMENT_AFTER = set(" \t;|&(){},=")


class UnreadablePowerShell(ValueError):
    """The text ends inside a string or a block comment."""


def code_text(text: str) -> str:
    """Every line of ``text`` with its comments dropped."""
    lines = text.splitlines()
    out: list[str] = []
    # The construct left open at the end of the previous line, if any:
    # "block" for <# #>, or the here-string terminator ('@ or "@), or the
    # quote character of an ordinary string that spans lines.
    open_: str | None = None
    for line in lines:
        kept: list[str] = []
        index = 0
        if open_ in ("'@", '"@'):
            # A here-string ends only at its terminator at the start of a line.
            if line.startswith(open_):
                kept.append(open_)
                index = 2
                open_ = None
            else:
                out.append(line)
                continue
        while index < len(line):
            char = line[index]
            if open_ == "block":
                end = line.find("#>", index)
                if end < 0:
                    index = len(line)
                    break
                index = end + 2
                open_ = None
                continue
            if open_ in ("'", '"'):
                if open_ == '"' and char == "`":
                    kept.append(line[index : index + 2])
                    index += 2
                    continue
                kept.append(char)
                index += 1
                if char == open_:
                    # A doubled quote is an escaped quote, not the end.
                    if index < len(line) and line[index] == open_:
                        kept.append(char)
                        index += 1
                    else:
                        open_ = None
                continue
            if line.startswith("<#", index):
                open_ = "block"
                index += 2
                continue
            if char == "@" and line[index + 1 : index + 2] in ("'", '"') and \
                    not line[index + 2 :].strip():
                open_ = line[index + 1] + "@"
                kept.append(line[index:])
                break
            if char in ("'", '"'):
                open_ = char
                kept.append(char)
                index += 1
                continue
            if char == "`":
                kept.append(line[index : index + 2])
                index += 2
                continue
            if char == "#" and (index == 0 or line[index - 1] in _COMMENT_AFTER):
                break
            kept.append(char)
            index += 1
        out.append("".join(kept))
    if open_ is not None:
        what = "block comment" if open_ == "block" else "string"
        raise UnreadablePowerShell(f"the text ends inside a {what}")
    return "\n".join(out)
