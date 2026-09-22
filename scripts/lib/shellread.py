#!/usr/bin/env python3
"""Read a shell file as shell, for the validators that have to.

Several validators ask the same three questions of a shell file: where does a
function start and stop, which words does it run as commands, and which lines
are therefore load-time code rather than a function body. Those three answers
used to be written out again in each validator that needed them, and the
copies neither agreed with one another nor were right. This module is the one
place they are answered, so a validator inherits the reading rather than a
fourth variant of it.

Two mistakes are what it exists to prevent, and both were live:

1. **Keyword shadowing.** A "word in command position" regex finds the callee
   by anchoring on what can open a command -- a line start, a `;`, a `&&`, a
   `then`. Shell keywords are among those openers, and a keyword is spelled
   like a function name, so a pattern whose callee group will accept anything
   word-shaped consumes the opener itself and never reaches the word it was
   opening. `if helper; then` reads as the two calls `if` and `then`, and
   `helper` is invisible. The consequences were not theoretical:
   ``validate-plan-network.py`` stopped requiring a script reached through
   `if helper; then` to be declared, which is exactly the failure its own
   docstring calls failing open -- the preflight never probes the host, and
   the run mutates before it discovers it cannot download. So `COMMAND`
   excludes the reserved words from its callee group with a negative
   lookahead, and it keeps the keywords in the opener alternation, which is
   what lets `if cond; then helper` match a second time on the same line and
   yield `helper` rather than `then`.

   The declaration builtins -- `local`, `declare`, `typeset`, `readonly`,
   `export` -- are excluded alongside the reserved words for the same reason:
   the word after them is a variable being declared, not a command being run,
   so capturing one as a callee invents a call that does not exist.

2. **Where the brace sits deciding what a function is.** A definition
   recognised only when its opening brace is on the same line makes the
   otherwise identical

       name()
       {

   invisible, and the body then reads as load-time code. That is how a tool
   floor could be enforced by a function nothing calls while the validator
   reported the file as enforcing it. `function_spans` scans forward over
   blank and comment lines for the brace, and accepts the `function name {`
   spelling as well.

Nothing here guesses. A file that cannot be read -- a definition with no
opening brace, a function that is never closed -- raises `UnreadableShell`,
because a validator that silently drops what it cannot parse reports success
for the thing it failed to check.
"""

from __future__ import annotations

import re
from typing import NamedTuple

# Words that can never be the callee of a command. The first group is shell's
# reserved words; the second is the declaration builtins, which are followed by
# a variable rather than by a command. Capturing any of them as a callee is the
# shadowing bug this module exists to prevent, so `COMMAND` refuses them.
RESERVED_WORDS = (
    "if", "then", "else", "elif", "fi",
    "do", "done", "while", "until", "for",
    "case", "esac", "function", "in",
    "return", "local", "declare", "typeset", "readonly", "export",
)
# What opens a command: the start of a line, a separator or pipeline operator,
# a subshell or a group, a negation, or a keyword that is followed by a command
# rather than by an argument. The character class covers `;`, `&&`, `||`, `$(`,
# `(`, `{`, `}` and `!` between them. `in` and `function` are deliberately not
# openers: the word after them is a pattern list or a function's own name.
_OPENER = r"(?:^|[;&|(){}!]|\b(?:then|else|elif|do|if|while|until)\b)"
# A word in command position. The lookahead is the whole point: without it the
# opener alternation matches `if`, the callee group swallows it, and the real
# callee after it is never seen.
COMMAND = re.compile(
    _OPENER
    + r"\s*(?!(?:" + "|".join(RESERVED_WORDS) + r")\b)"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b"
)
# A function definition, in either spelling this repository's shell may use:
# `name()`, with or without the `function` keyword, and `function name`. The
# opening brace is optional here because it is allowed to sit on a later line;
# `function_spans` is what goes looking for it.
DEFINITION = re.compile(
    r"^(?P<indent>[ \t]*)(?P<keyword>function[ \t]+)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*(?P<parens>\([ \t]*\))?[ \t]*"
    r"(?P<brace>\{)?"
)


class UnreadableShell(Exception):
    """This file could not be read as shell, so nothing about it is known."""


class FunctionSpan(NamedTuple):
    """One function: its name, the lines it occupies and its body text.

    `opens` is the line the definition starts on and `closes` the line its
    closing brace is on, both zero-based, so `range(opens, closes + 1)` is
    every line that belongs to the function. `body` is what the function runs,
    with the definition and the braces themselves removed.
    """

    name: str
    opens: int
    closes: int
    body: str


def strip_noise(line: str) -> str:
    """One line with its comment dropped and its quoted text blanked out.

    Quotes are kept so word boundaries survive; only the literal text inside
    them is replaced, because a reader's name written in a string is not a
    call. Command substitution is the exception that matters here: `"$(tool_floor
    nvim)"` runs `tool_floor` even though it sits inside double quotes, and
    that is how all four platform verifiers call it, so `$(` reopens ordinary
    shell and only the quoting around it is blanked. Single quotes substitute
    nothing, so their contents go entirely. A `#` opens a comment only at the
    start of a word, which is what leaves `${x#y}` and `$#` alone.

    The result lines up character for character with its input up to the
    comment that ends it, so an index found in the blanked line addresses the
    same character of the original.
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


def definition(line: str) -> re.Match[str] | None:
    """The function definition this line starts, or None.

    A bare word is an ordinary command, so a definition has to be marked as
    one: either by the `()` after its name or by the `function` keyword before
    it. Without that test every `printf ...` line would read as a definition.

    What follows has to be the opening brace or nothing, because a definition
    whose brace is merely absent is one whose brace is on a later line, and
    reporting an unreadable file is only useful when the file really was a
    definition. `function restoreGroup(item, path, saved) {` inside a
    heredoc of JavaScript is not one: shell takes no parameter list, so the
    trailing text is what tells the two apart.
    """
    match = DEFINITION.match(line)
    if match is None or not (match.group("parens") or match.group("keyword")):
        return None
    if match.group("brace") is None and line[match.end() :].strip():
        return None
    return match


def function_spans(lines: list[str]) -> list[FunctionSpan]:
    """Each function these lines define, in the order they are defined.

    The opening brace may sit on the definition's own line, on the next line,
    or past a run of blank and comment lines; all three are the same function,
    and treating the last two as load-time code is how a check can be left
    enforcing nothing. The closing brace is the one at the definition's own
    indentation rather than the first in column 0: this repository nests
    helper functions inside other functions, and taking column 0 as the
    terminator swallowed everything after one of them.

    A definition that never opens, and one that never closes, are parses this
    cannot trust, so each raises rather than guessing a span.
    """
    spans: list[FunctionSpan] = []
    index = 0
    while index < len(lines):
        match = definition(strip_noise(lines[index]))
        if match is None:
            index += 1
            continue
        name = match.group("name")
        indent = match.group("indent")

        if match.group("brace"):
            brace = index
            after = match.end("brace")
        else:
            brace = index + 1
            while brace < len(lines) and not strip_noise(lines[brace]).strip():
                brace += 1
            if brace >= len(lines) or strip_noise(lines[brace]).strip() != "{":
                raise UnreadableShell(
                    f"the function {name} defined on line {index + 1} is never "
                    f"opened by a '{{'"
                )
            after = strip_noise(lines[brace]).index("{") + 1

        tail = strip_noise(lines[brace])[after:]
        if "}" in tail:
            # The whole function on one line, which is this repository's usual
            # spelling for a one-statement wrapper.
            closes = brace
            body = lines[brace][after : after + tail.rindex("}")]
        else:
            closer = indent + "}"
            closes = brace + 1
            while closes < len(lines) and lines[closes].rstrip() != closer:
                closes += 1
            if closes >= len(lines):
                raise UnreadableShell(
                    f"the function {name} opened on line {brace + 1} is never "
                    f"closed by {closer!r}"
                )
            body = "\n".join([lines[brace][after:]] + lines[brace + 1 : closes])

        spans.append(FunctionSpan(name, index, closes, body))
        index = closes + 1
    return spans


def function_bodies(text: str) -> dict[str, str]:
    """Each function body in this shell text, by name, the first winning."""
    bodies: dict[str, str] = {}
    for span in function_spans(text.splitlines()):
        bodies.setdefault(span.name, span.body)
    return bodies


def outside_functions(text: str) -> str:
    """The text with every function body removed, leaving what runs on load."""
    lines = text.splitlines()
    inside: set[int] = set()
    for span in function_spans(lines):
        inside.update(range(span.opens, span.closes + 1))
    return "\n".join(
        line for number, line in enumerate(lines) if number not in inside
    )


def commands(text: str) -> set[str]:
    """Every word this shell text runs as a command."""
    found: set[str] = set()
    for line in text.splitlines():
        for match in COMMAND.finditer(strip_noise(line)):
            found.add(match.group("name"))
    return found
