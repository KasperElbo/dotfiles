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
  live in a function nothing calls and still read as reachable code.

This is a reader for *this repository's* shell, not a shell parser. It is
deliberately loud where it cannot read: a definition whose body never closes
raises ``UnreadableShell`` rather than being guessed at, because a validator
that silently drops a function reports a pass for something it never read.
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
# on one line, and `function name` with or without the parentheses.
DEFINITION = re.compile(
    r"^(?P<indent>\s*)(?:function\s+(?P<named>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\s*\(\))?|(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(\))\s*"
    r"(?:(?P<brace>\{)(?P<inline>.*))?\s*$"
)


class UnreadableShell(Exception):
    """Shell this reader will not guess at, so its caller must not pass it."""


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
    """
    out: list[str] = []
    # The innermost context: "" for ordinary shell and inside $(...), else the
    # quote character being matched. Substitution depth is tracked alongside so
    # a `)` only closes the substitution it belongs to.
    stack: list[str] = [""]
    depth = 0
    index = 0
    while index < len(line):
        character = line[index]
        context = stack[-1]
        if context == "'":
            out.append(character if character == "'" else " ")
            if character == "'":
                stack.pop()
            index += 1
            continue
        if line[index : index + 2] == "$(":
            out.append("$(")
            stack.append("")
            depth += 1
            index += 2
            continue
        if character == ")" and depth and context == "":
            out.append(")")
            stack.pop()
            depth -= 1
            index += 1
            continue
        if context == '"':
            out.append(character if character == '"' else " ")
            if character == '"':
                stack.pop()
            index += 1
            continue
        if character in "'\"":
            stack.append(character)
            out.append(character)
            index += 1
            continue
        if character == "#" and (index == 0 or line[index - 1].isspace()):
            break
        out.append(character)
        index += 1
    return "".join(out)


def commands(text: str) -> set[str]:
    """Every word this shell text runs as a command."""
    found: set[str] = set()
    for line in text.splitlines():
        for match in COMMAND.finditer(strip_noise(line)):
            found.add(match.group("name"))
    return found


def function_spans(lines: list[str]) -> list[tuple[str, int, int, str]]:
    """Each definition as (name, first line, closing line, body).

    Both indices are zero-based and the closing line is the last line the
    definition occupies, so the definition is ``lines[first : closing + 1]``.
    Three spellings are one definition here: the brace at the end of the
    definition's line, the brace on a line of its own below it, and a whole
    function written on one line. Which of the three is used says nothing
    about whether the body runs, so none of them may change the answer.

    The closing brace is the one at the definition's own indentation, not the
    first in column 0: this repository nests helper functions inside other
    functions, and taking column 0 as the terminator swallowed everything
    after one of them. A definition that never closes is a parse that cannot
    be trusted, so it raises rather than guessing a span.
    """
    spans: list[tuple[str, int, int, str]] = []
    index = 0
    while index < len(lines):
        match = DEFINITION.match(strip_noise(lines[index]))
        if match is None:
            index += 1
            continue
        name = match.group("named") or match.group("name")
        # Where the body starts is read from the blanked line, but the body
        # itself is taken from the original: blanking keeps every character's
        # position, and a caller reading paths or annotations out of a body
        # needs the text as written. `name() { run "$path"; }` is a whole
        # function, and handing back its blanked form loses the path.
        closed = (match.group("inline") or "").strip().endswith("}")
        inline = (
            lines[index][match.start("inline") : match.end("inline")].strip()
            if match.group("inline")
            else ""
        )
        if match.group("brace") is None:
            # `name()` alone on its line: the brace may be below it, with
            # blank lines or comments in between.
            ahead = index + 1
            while ahead < len(lines) and not strip_noise(lines[ahead]).strip():
                ahead += 1
            if ahead >= len(lines) or strip_noise(lines[ahead]).strip() != "{":
                # Not a definition this reader recognises. Leave the line to
                # the caller's other patterns rather than inventing a span.
                index += 1
                continue
            start = ahead + 1
        elif closed:
            spans.append((name, index, index, inline[:-1]))
            index += 1
            continue
        else:
            start = index + 1
        closer = match.group("indent") + "}"
        end = start
        while end < len(lines) and lines[end].rstrip() != closer:
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
