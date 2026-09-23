"""Read shell the way the validators need to read it, in one place.

Several validators have to answer the same three questions about a shell
file -- where does a function start and end, what does this text run, and
which of those words is a comment or a string rather than a command -- and
each of them grew its own regex for it. The copies drifted: one knew that a
reader called inside ``$( )`` is still a call and another did not, and both
shared a bug where the keyword opening a statement was captured as the word
the statement runs. ``CALL.finditer("if fedora_extra_step; then")`` yielded
``['if', 'then']``, so a helper reached through ``if helper; then`` was
invisible to every check built on it.

The two rules that keeps right:

* **A reserved word is never the callee.** ``if``, ``then``, ``do`` and the
  rest open a statement, so they belong to the opener alternation and are
  excluded from the name. Because the openers may restart inside a line,
  ``if cond; then helper`` yields ``helper`` rather than ``then``.
* **A definition is not a brace on one particular line.** ``name() {``,
  ``name()`` with the brace on the next line, and ``function name {`` are one
  definition in three spellings; treating only the first as real let a check
  live in a function nothing calls and still read as reachable code. A
  subshell body, ``name() ( ... )``, is the same definition again.
* **A line is read in the context of the lines before it.** A heredoc body,
  the second line of a quoted string and a ``case`` pattern all put a word
  first on its line, where a command would be. Read one line at a time, a
  ``usage()`` heredoc listing ``tool_floor_check`` was a call to it, so every
  gate asking "is this reader called anywhere" was satisfied by help text. The
  text is therefore blanked by one scan over the whole file (``blank_text``),
  and both ``commands()`` and ``function_spans()`` read that.

This is a reader for *this repository's* shell, not a shell parser. It is
deliberately loud where it cannot read: a definition whose body never closes,
and text that ends inside a string, a substitution, a heredoc or a ``case``,
raise ``UnreadableShell`` rather than being guessed at, because a validator
that silently misreads a file reports a pass for something it never read.
"""

from __future__ import annotations

import re

# The words that open or close a statement. None of them is ever the command a
# statement runs, so they are openers for the word that follows and are kept
# out of the name group.
RESERVED = (
    "if", "then", "elif", "else", "fi",
    "for", "while", "until", "do", "done",
    "case", "esac", "in", "select", "function", "time", "coproc",
)
_RESERVED = "|".join(RESERVED)
# A word in command position: the start of a line or of a new statement. The
# punctuation openers are every way this repository's shell begins one, `!`
# among them so `if ! tool_floor_check x; then` reaches the negated command,
# and an environment prefix among them so `PATH="$x" run_phase` reaches
# `run_phase`. `(` opens a subshell unless an `=` precedes it, where it opens
# an array literal instead and its words are data rather than commands.
_ASSIGNMENT = r"\b[A-Za-z_][A-Za-z0-9_]*=(?:[^\s\"'()]|\"[^\"]*\"|'[^']*')*\s+"
_OPENER = (
    r"(?:^|[;&|){}!]|(?<!=)\(|\|\||&&|\$\(|" + _ASSIGNMENT
    + r"|\b(?:" + _RESERVED + r")\b)"
)
COMMAND = re.compile(
    _OPENER + r"\s*(?P<name>(?!(?:" + _RESERVED + r")\b)[A-Za-z_][A-Za-z0-9_]*)\b(?!=)"
)
# `name() {`, `name()` with the brace on a following line, `name() { body; }`
# on one line, and `function name` with or without the parentheses. The body
# may equally be a subshell, `name() ( ... )`, which is still a definition and
# still does not run until something calls it.
DEFINITION = re.compile(
    r"^(?P<indent>\s*)(?:function\s+(?P<named>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*\(\))?|(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(\))\s*"
    r"(?:(?P<brace>[{(])(?P<inline>.*))?\s*$"
)
# What closes a body opened by each bracket.
CLOSER = {"{": "}", "(": ")"}


class UnreadableShell(Exception):
    """Shell this reader will not guess at, so its caller must not pass it."""


# `<<` or `<<-` and the delimiter word after it. A delimiter with any quoting
# in it makes the body literal; a bare one leaves `$( )` live inside the body.
HEREDOC = re.compile(
    r"<<(?P<strip>-)?[ \t]*"
    r"(?P<word>(?:[^\s;&|<>()'\"\\]|\\.|'[^'\n]*'|\"[^\"\n]*\")+)"
)
# The punctuation that makes the next word a command, for telling `case` the
# keyword from `case` an argument.
_COMMAND_START = re.compile(
    r"(?:^|[;&|({!]|\b(?:then|do|else|elif|if|while|until)\b)[ \t]*\Z"
)
# The tokens a `case` statement is read by: its keywords, the arm terminators,
# and any other word, which is where a pattern starts.
CASE_TOKEN = re.compile(r";;&|;;|;&|[()|&]|[^\s;()|&]+")


class _Frame:
    """One open context: ordinary shell, a quote, or a heredoc body."""

    __slots__ = ("kind", "parens", "delimiter", "strip_tabs", "opened")

    def __init__(self, kind: str, opened: int, *, delimiter: str = "",
                 strip_tabs: bool = False) -> None:
        self.kind = kind
        self.parens = 0
        self.delimiter = delimiter
        self.strip_tabs = strip_tabs
        self.opened = opened


def _line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def _blank(text: str, strict: bool) -> str:
    """The text with comments dropped and quoted and heredoc text blanked.

    Every line keeps its number and every character before a comment keeps its
    column, so a position found in the result is the same position in `text`.
    A comment is cut rather than blanked, which makes a line's blanked length
    the column its code ends at. The scan carries its state across lines, which
    is the whole point of doing it on the text rather than a line at a time: a
    heredoc body and the second line of a quoted string are data, and read one
    line at a time they looked like commands.

    With `strict`, text that ends inside a quote, a substitution or a heredoc
    raises `UnreadableShell`: whatever comes after an unclosed quote is read
    the wrong way round, and a validator must not report on it.
    """
    out: list[str] = []
    stack: list[_Frame] = [_Frame("", 0)]
    # Heredocs whose opener has been read on this line; each body starts on the
    # line after the command that opened it, in the order they were written.
    pending: list[_Frame] = []
    index = 0
    length = len(text)
    at_line_start = True
    while index < length:
        frame = stack[-1]
        character = text[index]
        if frame.kind == "heredoc" or frame.kind == "heredoc-quoted":
            if at_line_start:
                end = text.find("\n", index)
                end = length if end == -1 else end
                line = text[index:end]
                candidate = line.lstrip("\t") if frame.strip_tabs else line
                if candidate == frame.delimiter:
                    # The terminator is not a command either.
                    out.append(" " * len(line))
                    index = end
                    stack.pop()
                    at_line_start = False
                    continue
            at_line_start = False
            if character == "\n":
                out.append("\n")
                at_line_start = True
                index += 1
                continue
            if frame.kind == "heredoc":
                if character == "\\" and index + 1 < length and text[index + 1] != "\n":
                    out.append("  ")
                    index += 2
                    continue
                if text.startswith("$(", index) and not text.startswith("$((", index):
                    out.append("$(")
                    stack.append(_Frame("$(", index))
                    index += 2
                    continue
            out.append(" ")
            index += 1
            continue
        at_line_start = False
        if frame.kind == "'":
            if character == "'":
                stack.pop()
                out.append("'")
            else:
                out.append("\n" if character == "\n" else " ")
                at_line_start = character == "\n"
            index += 1
            continue
        if frame.kind in ('"', "$'"):
            if character == "\\" and index + 1 < length:
                following = text[index + 1]
                out.append(" " + ("\n" if following == "\n" else " "))
                index += 2
                continue
            closer = '"' if frame.kind == '"' else "'"
            if character == closer:
                stack.pop()
                out.append(character)
                index += 1
                continue
            if (
                frame.kind == '"'
                and text.startswith("$(", index)
                and not text.startswith("$((", index)
            ):
                out.append("$(")
                stack.append(_Frame("$(", index))
                index += 2
                continue
            out.append("\n" if character == "\n" else " ")
            index += 1
            continue
        # Ordinary shell, at the top level or inside `$( )`.
        if character == "\\" and index + 1 < length:
            out.append(text[index : index + 2])
            index += 2
            continue
        if text.startswith("$((", index) or (
            text.startswith("((", index) and (index == 0 or text[index - 1] != "$")
        ):
            # Arithmetic: `<<` in here is a shift, not a heredoc. It is code,
            # so it is kept as written up to the parenthesis that closes it.
            start = index
            index += 3 if text[index] == "$" else 2
            depth = 2
            while index < length and depth:
                if text[index] == "(":
                    depth += 1
                elif text[index] == ")":
                    depth -= 1
                index += 1
            if depth:
                if strict:
                    raise UnreadableShell(
                        f"the arithmetic opened on line {_line_number(text, start)} "
                        f"is never closed"
                    )
            out.append(text[start:index])
            continue
        if text.startswith("$(", index):
            out.append("$(")
            stack.append(_Frame("$(", index))
            index += 2
            continue
        if text.startswith("$'", index):
            out.append("$'")
            stack.append(_Frame("$'", index))
            index += 2
            continue
        if character in "'\"":
            out.append(character)
            stack.append(_Frame(character, index))
            index += 1
            continue
        if character == "(" and frame.kind == "$(":
            frame.parens += 1
        elif character == ")" and frame.kind == "$(":
            if frame.parens:
                frame.parens -= 1
            else:
                stack.pop()
                out.append(")")
                index += 1
                continue
        if character == "#" and (index == 0 or text[index - 1].isspace()):
            end = text.find("\n", index)
            index = length if end == -1 else end
            continue
        if text.startswith("<<<", index):
            # A here-string: its word is ordinary shell on this line.
            out.append("<<<")
            index += 3
            continue
        if text.startswith("<<", index):
            opener = HEREDOC.match(text, index)
            if opener is not None:
                word = opener.group("word")
                quoted = any(mark in word for mark in "'\"\\")
                delimiter = re.sub(r"\\(.)", r"\1", word).replace("'", "").replace('"', "")
                pending.append(
                    _Frame(
                        "heredoc-quoted" if quoted else "heredoc",
                        index,
                        delimiter=delimiter,
                        strip_tabs=bool(opener.group("strip")),
                    )
                )
                out.append(opener.group(0))
                index = opener.end()
                continue
        if character == "\n":
            out.append("\n")
            index += 1
            at_line_start = True
            if pending:
                # Bodies are read in order; the last one written is read last,
                # so it goes on the stack first.
                stack.extend(reversed(pending))
                pending = []
            continue
        out.append(character)
        index += 1
    if strict and (len(stack) > 1 or pending):
        frame = stack[-1] if len(stack) > 1 else pending[0]
        what = {
            "'": "single-quoted string",
            '"': "double-quoted string",
            "$'": "$'...' string",
            "$(": "command substitution",
            "heredoc": f"heredoc (terminator {frame.delimiter!r})",
            "heredoc-quoted": f"heredoc (terminator {frame.delimiter!r})",
        }[frame.kind]
        raise UnreadableShell(
            f"the {what} opened on line {_line_number(text, frame.opened)} is "
            f"never closed"
        )
    return "".join(out)


def strip_noise(line: str) -> str:
    """One line with its comment dropped and its quoted text blanked out.

    Quotes are kept so word boundaries survive; only the literal text inside
    them is replaced, because a reader's name written in a string is not a
    call. Command substitution is the exception that matters here:
    ``"$(tool_floor nvim)"`` runs ``tool_floor`` even though it sits inside
    double quotes, so ``$(`` reopens ordinary shell and only the quoting
    around it is blanked. Single quotes substitute nothing, so their contents
    go entirely. A ``#`` opens a comment only at the start of a word, which is
    what leaves ``${x#y}`` and ``$#`` alone.

    This is the one-line view, for a caller holding a fragment of a line. A
    whole file goes through ``blank_text``, because a line read on its own
    cannot know it is the second line of a string or the body of a heredoc.
    """
    return _blank(line, strict=False)


def blank_text(text: str) -> str:
    """``strip_noise`` for a whole file, reading each line in its context.

    A heredoc body is blanked through its terminator, a quote left open at the
    end of a line stays open on the next, and the terminator itself is blanked
    because it is not a command. Text that ends inside any of them raises
    ``UnreadableShell`` rather than being read with its quoting inverted.
    """
    return _blank(text, strict=True)


def code_line(line: str) -> str:
    """One line with its comment dropped and everything else left as written.

    ``strip_noise`` preserves every character's position and stops at the
    comment, so the blanked line's length is where the code ends: the blanking
    locates the comment without being what is read back. That matters because
    ``strip_noise`` also empties quoted text, which is right for a command name
    -- a reader's name inside a string is not a call -- and wrong for anything
    whose value lives in a string. ``"$DOTFILES_ROOT/config"`` is a real read
    of that variable, an assignment's value and a ``case`` subject are real
    text, and all three come back blank from ``strip_noise``.

    It strips the comment and nothing else, deliberately. A version that also
    trimmed whitespace or removed quotes would lose the distinction between
    ``ai_codex=''``, the empty string that means a sub-flag was omitted, and a
    variable that was never set.
    """
    return line[: len(strip_noise(line))]


def code_text(text: str) -> str:
    """The same for a whole file: every line with its comment dropped.

    The comment is found by ``blank_text``, so a ``#`` inside a heredoc body or
    on the second line of a string is kept as the text it is.
    """
    lines = text.splitlines()
    blanked = blank_text(text).split("\n")
    return "\n".join(line[: len(clean)] for line, clean in zip(lines, blanked))


def without_case_patterns(blanked: str) -> str:
    """Blanked shell with every ``case`` arm's pattern blanked as well.

    ``tool_floor_check)`` at the head of an arm is a word the subject is
    compared with, not a command, but it sits where a command would: first on
    its line, or after the ``|`` of the pattern before it. So the patterns go,
    from ``in`` or ``;;`` to the ``)`` that ends them, and the arm bodies stay.
    Nested ``case`` statements are followed through their ``esac``.
    """
    out = list(blanked)
    # One entry per open `case`: "head" until its `in`, "pattern" until the
    # arm's `)`, then "body" until `;;` or `esac`.
    stack: list[str] = []
    position = 0
    while True:
        token = CASE_TOKEN.search(blanked, position)
        if token is None:
            break
        word = token.group(0)
        position = token.end()
        mode = stack[-1] if stack else None
        if mode == "pattern":
            if word == "esac":
                stack.pop()
                continue
            end = _pattern_end(blanked, token.start())
            for index in range(token.start(), end + 1):
                if out[index] != "\n":
                    out[index] = " "
            stack[-1] = "body"
            position = end + 1
        elif word == "case" and mode in (None, "body"):
            line_start = blanked.rfind("\n", 0, token.start()) + 1
            if _COMMAND_START.search(blanked[line_start : token.start()]):
                stack.append("head")
        elif mode == "head" and word == "in":
            stack[-1] = "pattern"
        elif mode == "body" and word in (";;", ";&", ";;&"):
            stack[-1] = "pattern"
        elif mode == "body" and word == "esac":
            stack.pop()
    if stack:
        raise UnreadableShell("a case statement is never closed by 'esac'")
    return "".join(out)


def _pattern_end(blanked: str, start: int) -> int:
    """The index of the `)` closing the case pattern that begins at `start`.

    A pattern may open with its own `(`, and an extended glob such as
    `@(a|b)` nests a pair inside it; neither closes the pattern.
    """
    index = start + 1 if blanked[start] == "(" else start
    depth = 0
    while index < len(blanked):
        character = blanked[index]
        if character == "(":
            depth += 1
        elif character == ")":
            if depth == 0:
                return index
            depth -= 1
        index += 1
    raise UnreadableShell(
        f"the case pattern starting on line {_line_number(blanked, start)} "
        f"is never closed by ')'"
    )


def commands(text: str) -> set[str]:
    """Every word this shell text runs as a command.

    The text is read as a whole: a heredoc body, a string's continuation line
    and a ``case`` pattern are all words in command position when a line is
    read on its own, and none of them runs. A backslash-newline joins two lines
    into one command, so the word after it is an argument, not a new command.
    """
    blanked = without_case_patterns(blank_text(text))
    found: set[str] = set()
    for line in re.sub(r"\\\n", "  ", blanked).splitlines():
        for match in COMMAND.finditer(line):
            found.add(match.group("name"))
    return found


def function_spans(lines: list[str]) -> list[tuple[str, int, int, str]]:
    """Each definition as (name, first line, closing line, body).

    Both indices are zero-based and the closing line is the last line the
    definition occupies, so the definition is ``lines[first : closing + 1]``.
    Three spellings are one definition here: the brace at the end of the
    definition's line, the brace on a line of its own below it, and a whole
    function written on one line. Which of the three is used says nothing
    about whether the body runs, so none of them may change the answer, and
    neither may a subshell body in place of the braces.

    The closing brace is the one at the definition's own indentation, not the
    first in column 0: this repository nests helper functions inside other
    functions, and taking column 0 as the terminator swallowed everything
    after one of them. It is found in the blanked text, so a comment after it
    still closes the function and a ``}`` inside a heredoc does not. A
    definition that never closes is a parse that cannot be trusted, so it
    raises rather than guessing a span.
    """
    blanked = blank_text("\n".join(lines)).split("\n")
    spans: list[tuple[str, int, int, str]] = []
    index = 0
    while index < len(lines):
        match = DEFINITION.match(blanked[index])
        if match is None:
            index += 1
            continue
        name = match.group("named") or match.group("name")
        opener = match.group("brace")
        # Where the body starts is read from the blanked line, but the body
        # itself is taken from the original: blanking keeps every character's
        # position, and a caller reading paths or annotations out of a body
        # needs the text as written. `name() { run "$path"; }` is a whole
        # function, and handing back its blanked form loses the path.
        inline = (
            lines[index][match.start("inline") : match.end("inline")].strip()
            if match.group("inline")
            else ""
        )
        if opener is None:
            # `name()` alone on its line: the brace may be below it, with
            # blank lines or comments in between.
            ahead = index + 1
            while ahead < len(lines) and not blanked[ahead].strip():
                ahead += 1
            if ahead >= len(lines) or blanked[ahead].strip() not in CLOSER:
                # Not a definition this reader recognises. Leave the line to
                # the caller's other patterns rather than inventing a span.
                index += 1
                continue
            opener = blanked[ahead].strip()
            start = ahead + 1
        elif (match.group("inline") or "").strip().endswith(CLOSER[opener]):
            spans.append((name, index, index, inline[:-1]))
            index += 1
            continue
        else:
            start = index + 1
        closer = match.group("indent") + CLOSER[opener]
        end = start
        while end < len(lines) and blanked[end].rstrip() != closer:
            end += 1
        if end >= len(lines):
            raise UnreadableShell(
                f"the function {name} opened on line {index + 1} is never "
                f"closed by {closer!r}"
            )
        body = ([inline] if inline else []) + lines[start:end]
        spans.append((name, index, end, "\n".join(body)))
        index = end + 1
    return spans


def shell_functions(text: str) -> dict[str, str]:
    """Each function body in this shell text, by name, first definition winning."""
    bodies: dict[str, str] = {}
    for name, _, _, body in function_spans(text.splitlines()):
        bodies.setdefault(name, body)
    return bodies


def outside_functions(text: str) -> str:
    """The text with every function body removed, leaving what runs on load."""
    lines = text.splitlines()
    inside: set[int] = set()
    for _, opened, end, _ in function_spans(lines):
        inside.update(range(opened, end + 1))
    return "\n".join(line for number, line in enumerate(lines) if number not in inside)


def close_over(start: set[str], bodies: dict[str, str]) -> set[str]:
    """Everything reachable from `start` by calling the functions in `bodies`."""
    reached = set(start)
    pending = list(start)
    while pending:
        name = pending.pop()
        for called in commands(bodies.get(name, "")):
            if called not in reached:
                reached.add(called)
                pending.append(called)
    return reached
