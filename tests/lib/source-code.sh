#!/usr/bin/env bash

# Read a tracked shell or PowerShell source as code: comments dropped, every
# line kept in place. Sourced by tests/lib/test.sh, and on its own by suites
# that do not use that library; sourcing it changes no shell option.

# A failed assertion counts through the test library when it is loaded, and is
# still reported, with a failing status, when it is not.
_source_code_fail() {
  if declare -F _test_die >/dev/null; then
    _test_die "$@"
  else
    printf 'TEST FAILURE: %s\n' "$*" >&2
  fi
  return 1
}

_SOURCE_CODE_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)"
# Resolved now, because suites that isolate PATH to prove a command is absent
# still read their sources after doing so.
_SOURCE_CODE_PYTHON="$(command -v python3 || true)"

# source_code <file>: a tracked shell or PowerShell source with its comments
# dropped and every line kept in place, so a line number still points at the
# source. Strings are kept: a message or a path is code the script runs.
#
# The code_* assertions below read this rather than the raw file. A raw search
# cannot tell a call from a comment naming it, so replacing a real call with a
# comment that names it passed every assertion looking for the call (issue
# #537). Shell goes through scripts/lib/shell.py and PowerShell through
# scripts/lib/powershell.py; anything else is refused rather than read raw.
source_code() {
  local path="$1"
  [[ -r "$path" ]] || {
    _source_code_fail "file is not readable: $path"
    return 1
  }
  [[ -n "$_SOURCE_CODE_PYTHON" ]] || {
    _source_code_fail "python3 was not on PATH when tests/lib/source-code.sh was sourced"
    return 1
  }
  PYTHONPATH="$_SOURCE_CODE_LIB" "$_SOURCE_CODE_PYTHON" - "$path" <<'PYTHON'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
if path.suffix in (".ps1", ".psm1"):
    from powershell import code_text

    text = path.read_text(encoding="utf-8-sig")
else:
    from shell import code_text

    text = path.read_text()
    first = text.split("\n", 1)[0]
    named = path.suffix in (".sh", ".bash", ".zsh") or path.name.startswith(".zsh")
    if not named and not re.match(r"#!.*\b(ba|z|da)?sh\b", first):
        sys.exit(f"{path} is neither shell nor PowerShell; read a data file with grep")
sys.stdout.write(code_text(text) + "\n")
PYTHON
}

# code_grep <grep argument>... <file>: grep over `source_code <file>`, with
# grep's status. A file the reader cannot read ends the suite: returning a
# status would let `if code_grep ...; then fail; fi` read it as "no match".
code_grep() {
  local path="${!#}" code argument
  # One file only: a second one would be taken for a pattern and silently
  # never read. Suites name sources by absolute path, and a pattern such as
  # 'common/install-ai.sh' is relative, so only an absolute file is refused.
  for argument in "${@:1:$#-1}"; do
    [[ "$argument" != /* || ! -f "$argument" ]] || {
      _source_code_fail "code_grep reads one file; $argument was passed as well as $path"
      exit 1
    }
  done
  code="$(source_code "$path")" || {
    _source_code_fail "could not read the code of $path"
    exit 1
  }
  grep "${@:1:$#-1}" <<<"$code"
}

# assert_code_contains <file> <needle>: the needle is in the file's code, not
# only in a comment.
assert_code_contains() {
  code_grep -Fq -- "$2" "$1" ||
    _source_code_fail "expected the code of $1 (comments dropped) to contain '$2'"
}

# assert_code_line <file> <line>: an exact line of the file's code.
assert_code_line() {
  code_grep -Fxq -- "$2" "$1" ||
    _source_code_fail "expected the code of $1 (comments dropped) to contain exact line '$2'"
}

# assert_code_not_contains <file> <needle>: the needle is not in the file's
# code. Prose may name it: a comment explaining why something is absent is not
# the thing itself.
assert_code_not_contains() {
  if code_grep -Fq -- "$2" "$1"; then
    _source_code_fail "expected the code of $1 (comments dropped) not to contain '$2'"
  fi
}
