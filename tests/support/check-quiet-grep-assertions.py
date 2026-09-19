#!/usr/bin/env python3
"""Find tests that pipe a producer into a quiet grep.

`grep -q` exits at its first match, so the producer on the left of the pipe
is left writing to a closed pipe: it takes SIGPIPE and exits non-zero. The
suites run under `set -o pipefail`, so that becomes the pipeline's status, and
the pipeline then reports something about the writer rather than about the
match. Both directions are unsound, and the pipeline's status is wrong in
exactly the case each assertion exists to detect:

    producer | grep -Fq needle || _test_die '...'     fails when the needle IS
                                                      present -- a loud flake

    if producer | grep -Fq needle; then _test_die     does nothing when the
                                                      needle IS present -- a
                                                      silent pass

    $ bash -c 'set -o pipefail
    >   if seq 1 200000 | grep -q "^1$"; then echo CAUGHT; else echo MISSED; fi'
    MISSED

Both survive today only because most producers are small enough to finish
before grep exits, which is the property that changes under load. So the rule
is one rule: a test never pipes into a quiet grep. Read the producer into a
variable and match against a here-string instead --
`result="$(producer)"; grep -Fq needle <<<"$result"` -- which reads the
producer to its end and leaves grep's own status to speak for the match.

Finding every one of them reliably still means reading the suites as shell:
quotes, escapes, comments, here-documents, command and process substitutions
and the payload of an inline `bash -c` all hide pipelines from a text search.
Anything that does not tokenise is reported as an error rather than skipped.
"""

from __future__ import annotations

import sys

# Characters that end a word and begin an operator.
OPERATOR_CHARS = set("|&;()<>\n")

# Multi-character operators, longest first.
OPERATORS = (";;&", "<<<", "<<-", ";;", ";&", "&&", "||", "|&", "<<", ">>",
             "<&", ">&", "<>", ">|")

class ParseError(Exception):
    pass


class Token:
    __slots__ = ("kind", "text", "line", "quoted")

    def __init__(self, kind, text, line, quoted=False):
        self.kind = kind  # 'word' or 'op'
        self.text = text
        self.line = line
        self.quoted = quoted

    def is_op(self, *texts):
        return self.kind == "op" and (not texts or self.text in texts)

    def is_word(self, *texts):
        return self.kind == "word" and (not texts or self.text in texts)


class Lexer:
    """A Bash lexer that keeps enough structure to read a pipeline's context.

    Command substitutions are lexed recursively into their own token lists, so
    a `$( ... )` holding a here-document -- which no bracket counting survives
    -- is read as the shell reads it.
    """

    def __init__(self, src, path):
        self.src = src
        self.path = path
        self.pos = 0
        self.line = 1
        self.streams = []  # every token list found, outermost first

    def fail(self, message, line=None):
        raise ParseError(f"{self.path}:{line or self.line}: {message}")

    def run(self):
        tokens = self.lex(stop_at_paren=False)
        self.streams.insert(0, tokens)
        if self.pos < len(self.src):
            self.fail("unbalanced ')'")
        return self.streams

    def lex(self, stop_at_paren):
        """Lex until end of input, or until the `)` that closes this level."""
        src, n = self.src, len(self.src)
        tokens = []
        pending_heredocs = []
        expect_delimiter = False

        while self.pos < n:
            c = src[self.pos]
            if c == "\\" and self.pos + 1 < n and src[self.pos + 1] == "\n":
                self.pos += 2
                self.line += 1
                continue
            if c in " \t":
                self.pos += 1
                continue
            if c == "\n":
                # A newline right after `|`, `||` or `&&` continues the list
                # rather than ending a command, exactly as the shell reads it.
                if not (tokens and tokens[-1].is_op("|", "|&", "||", "&&")):
                    tokens.append(Token("op", "\n", self.line))
                self.pos += 1
                self.line += 1
                if pending_heredocs:
                    self.skip_heredocs(pending_heredocs)
                    pending_heredocs = []
                continue
            if c == "#":
                # A `#` opens a comment only at the start of a word, which is
                # where this loop is. Blanking comments this way is what the
                # repository's `code_text()` helpers do, one level stricter.
                end = src.find("\n", self.pos)
                self.pos = n if end < 0 else end
                continue
            if c == ")" and stop_at_paren:
                self.pos += 1
                return tokens
            if c in OPERATOR_CHARS:
                if c in "<>" and src.startswith("(", self.pos + 1):
                    # Process substitution: lex the inside as its own command.
                    self.pos += 2
                    self.streams.append(self.lex(stop_at_paren=True))
                    tokens.append(Token("word", f"{c}(...)", self.line, True))
                    continue
                op = next((o for o in OPERATORS if src.startswith(o, self.pos)),
                          c)
                tokens.append(Token("op", op, self.line))
                self.pos += len(op)
                if op in ("<<", "<<-"):
                    expect_delimiter = True
                continue
            start_line = self.line
            text, quoted = self.read_word()
            if not text and not quoted:
                self.fail(f"could not read a word at {src[self.pos:][:20]!r}")
            if expect_delimiter:
                pending_heredocs.append((text, tokens[-1].text == "<<-"))
                expect_delimiter = False
            tokens.append(Token("word", text, start_line, quoted))

        if stop_at_paren:
            self.fail("unterminated command substitution")
        return tokens

    def skip_heredocs(self, pending):
        src, n = self.src, len(self.src)
        for delimiter, strip_tabs in pending:
            opened = self.line - 1
            while True:
                if self.pos >= n:
                    self.fail(f"unterminated here-document '{delimiter}'",
                              opened)
                end = src.find("\n", self.pos)
                body = src[self.pos:end] if end >= 0 else src[self.pos:]
                candidate = body.lstrip("\t") if strip_tabs else body
                self.pos = n if end < 0 else end + 1
                self.line += 1
                if candidate.rstrip("\r") == delimiter:
                    break

    def read_word(self):
        """Read one word, honouring every form of quoting; return (text, quoted)."""
        src, n = self.src, len(self.src)
        out = []
        quoted = False
        while self.pos < n:
            c = src[self.pos]
            if c in " \t" or c in OPERATOR_CHARS:
                break
            if c == "\\":
                if self.pos + 1 >= n:
                    self.fail("trailing backslash")
                if src[self.pos + 1] == "\n":
                    self.line += 1
                    self.pos += 2
                    continue
                out.append(src[self.pos + 1])
                quoted = True
                self.pos += 2
                continue
            if c == "'":
                end = src.find("'", self.pos + 1)
                if end < 0:
                    self.fail("unterminated single quote")
                out.append(src[self.pos + 1:end])
                self.line += src.count("\n", self.pos, end)
                quoted = True
                self.pos = end + 1
                continue
            if c == '"':
                out.append(self.read_double_quoted())
                quoted = True
                continue
            if c == "$" and src.startswith("$((", self.pos):
                out.append(self.skip_arithmetic())
                continue
            if c == "$" and src.startswith("$(", self.pos):
                self.pos += 2
                self.streams.append(self.lex(stop_at_paren=True))
                out.append("$(...)")
                continue
            if c == "`":
                end = src.find("`", self.pos + 1)
                if end < 0:
                    self.fail("unterminated backquote")
                inner = Lexer(src[self.pos + 1:end], self.path)
                self.streams.extend(inner.run())
                self.line += src.count("\n", self.pos, end)
                out.append("`...`")
                self.pos = end + 1
                continue
            out.append(c)
            self.pos += 1
        return "".join(out), quoted

    def read_double_quoted(self):
        src, n = self.src, len(self.src)
        out = []
        self.pos += 1
        while self.pos < n and src[self.pos] != '"':
            c = src[self.pos]
            if c == "\\" and self.pos + 1 < n:
                if src[self.pos + 1] == "\n":
                    self.line += 1
                out.append(src[self.pos + 1])
                self.pos += 2
                continue
            if c == "$" and src.startswith("$((", self.pos):
                out.append(self.skip_arithmetic())
                continue
            if c == "$" and src.startswith("$(", self.pos):
                self.pos += 2
                self.streams.append(self.lex(stop_at_paren=True))
                out.append("$(...)")
                continue
            if c == "`":
                end = src.find("`", self.pos + 1)
                if end < 0:
                    self.fail("unterminated backquote")
                inner = Lexer(src[self.pos + 1:end], self.path)
                self.streams.extend(inner.run())
                self.line += src.count("\n", self.pos, end)
                out.append("`...`")
                self.pos = end + 1
                continue
            if c == "\n":
                self.line += 1
            out.append(c)
            self.pos += 1
        if self.pos >= n:
            self.fail("unterminated double quote")
        self.pos += 1
        return "".join(out)

    def skip_arithmetic(self):
        src, n = self.src, len(self.src)
        depth = 0
        j = self.pos + 1
        while j < n:
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
                if depth == 0:
                    self.line += src.count("\n", self.pos, j + 1)
                    self.pos = j + 1
                    return "$((...))"
            j += 1
        self.fail("unterminated arithmetic expansion")


def has_quiet_flag(tokens, start):
    """True when the grep command starting at `start` was given a quiet flag."""
    for token in tokens[start + 1:]:
        if not token.is_word():
            break
        if token.quoted or not token.text.startswith("-") or token.text in ("-", "--"):
            break
        if token.text in ("--quiet", "--silent"):
            return True
        if not token.text.startswith("--") and "q" in token.text[1:]:
            return True
    return False


def findings_in_stream(tokens, lines):
    """Yield (line, source line) for every quiet grep that reads a pipe."""
    return [(token.line, lines[token.line - 1].strip())
            for index, token in enumerate(tokens)
            if token.is_word("grep") and index > 0
            and tokens[index - 1].is_op("|")
            and has_quiet_flag(tokens, index)]


# A word carrying one of these placeholders was rewritten by the lexer, so its
# text is no longer the shell a child would run.
PLACEHOLDERS = ("$(...)", "`...`", "$((...))", "<(...)", ">(...)")


def inline_payloads(tokens):
    """Yield (shell text, line) for every `bash -c '<script>'` in a stream.

    A suite that drives a child shell writes that shell inline, so the payload
    is shell this check has to read too.
    """
    for index, token in enumerate(tokens[:-2]):
        if not token.is_word("bash", "sh", "zsh") or token.quoted:
            continue
        if not tokens[index + 1].is_word("-c") or tokens[index + 1].quoted:
            continue
        payload = tokens[index + 2]
        if not payload.is_word() or not payload.quoted:
            continue
        if any(marker in payload.text for marker in PLACEHOLDERS):
            continue
        yield payload.text, payload.line


def scan(path):
    with open(path, "r", encoding="utf-8") as handle:
        src = handle.read()
    found = []
    for stream in Lexer(src, path).run():
        found.extend(findings_in_stream(stream, src.splitlines()))
        for payload, at in inline_payloads(stream):
            for inner in Lexer(payload, path).run():
                found.extend((at + line - 1, text) for line, text
                             in findings_in_stream(inner, payload.splitlines()))
    return sorted(set(found))


def main(argv):
    if len(argv) < 2:
        print("usage: check-quiet-grep-assertions.py <shell file>...",
              file=sys.stderr)
        return 2
    failed = False
    for path in argv[1:]:
        try:
            found = scan(path)
        except ParseError as error:
            print(f"cannot read as shell: {error}", file=sys.stderr)
            return 2
        except OSError as error:
            print(f"cannot read {path}: {error}", file=sys.stderr)
            return 2
        for line, text in found:
            failed = True
            print(f"{path}:{line}: pipes a producer into a quiet grep")
            print(f"    {text}")
    if failed:
        print(
            "A quiet grep exits at its first match, so the producer is left "
            "writing to a\nclosed pipe: it takes SIGPIPE, and pipefail makes "
            "that the pipeline's status. The\npipeline then reports on the "
            "writer rather than on the match, and it does so in\nexactly the "
            "case the assertion exists to detect -- failing when the text IS\n"
            "present, or passing when it is. Read the producer into a variable "
            "and match\nagainst a here-string instead: result=\"$(producer)\"; "
            "grep -Fq needle <<<\"$result\".",
            file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
