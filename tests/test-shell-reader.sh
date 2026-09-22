#!/usr/bin/env bash
# The one shell reader the validators share, and the two rules it exists for.
#
# `scripts/lib/shell.py` answers three questions about a shell file -- where a
# function starts and ends, what a piece of text runs, and which words are
# comments or strings rather than commands. Several validators used to answer
# them with a regex each, and the copies drifted into two defects this suite
# holds closed:
#
# 1. The keyword that opens a statement was captured as the command the
#    statement runs, so `if helper; then` reported `if` and `then` and the real
#    callee was invisible. A helper reached that way was never required to be
#    declared (GAP-43).
# 2. A definition was recognised only with its brace on the same line, so the
#    same function moved its body between "code that runs" and "a function
#    nothing calls" depending on where the brace sat -- passing an uncalled
#    floor check and refusing an enforced one (GAP-45).
#
# So each spelling of a definition and each way of reaching a command gets a
# case here, in the reader itself rather than through one of its callers.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# read <function> <<<text: the reader's answer for one piece of shell, printed
# as a sorted line so an assertion reads like the shell it is about.
reader() {
  # The shell under test arrives on stdin, and the reader script takes stdin's
  # place, so it is handed over in the environment rather than read from there.
  local text
  text="$(cat)"
  SHELL_UNDER_TEST="$text" PYTHONPATH="$repo_root/scripts/lib" python3 - "$1" <<'PYTHON'
import os
import sys

import shell

text = os.environ["SHELL_UNDER_TEST"]
question = sys.argv[1]
if question == "commands":
    print(" ".join(sorted(shell.commands(text))))
elif question == "functions":
    print(" ".join(sorted(shell.shell_functions(text))))
elif question == "bodies":
    for name, body in sorted(shell.shell_functions(text).items()):
        print(f"{name}: {' '.join(body.split())}")
elif question == "outside":
    print(" ".join(shell.outside_functions(text).split()))
elif question == "code":
    # Printed between markers, because what this answers about is exactly the
    # whitespace and quoting an unmarked print would hide.
    print(f"[{shell.code_text(text)}]")
elif question == "spans":
    for name, opened, closed, _ in shell.function_spans(text.splitlines()):
        print(f"{name} {opened} {closed}")
else:
    raise SystemExit(f"unknown question {question}")
PYTHON
}

# --- A reserved word is never the command a statement runs ------------------

# The exact shape that hid a helper from every check built on the old regex:
# the callee sits between `if` and `then`, and both keywords used to be
# reported in its place.
run_capture reader commands <<<'if fedora_extra_step; then'
assert_success
assert_eq 'fedora_extra_step' "$TEST_OUTPUT" \
  'the callee of `if helper; then`, not the keywords around it'

run_capture reader commands <<<'if [[ "$x" == y ]]; then fedora_extra_step; fi'
assert_success
assert_eq 'fedora_extra_step' "$TEST_OUTPUT" \
  'a one-line if runs the helper in its body'

run_capture reader commands <<<'if ! tool_floor_check nvim; then die "too old"; fi'
assert_success
assert_eq 'die tool_floor_check' "$TEST_OUTPUT" \
  'a negated command runs, and so does the one in the then-branch'

run_capture reader commands <<<'while helper; do work; done'
assert_success
assert_eq 'helper work' "$TEST_OUTPUT" 'a while condition runs its command'

run_capture reader commands <<<'elif other_helper; then'
assert_success
assert_eq 'other_helper' "$TEST_OUTPUT" 'elif opens a statement like if'

run_capture reader commands <<<'{ grouped; } && (subshelled)'
assert_success
assert_eq 'grouped subshelled' "$TEST_OUTPUT" \
  'a group and a subshell both open a statement'

# Command substitution runs even inside double quotes, which is how all four
# platform verifiers read a tool floor.
run_capture reader commands <<<'printf "%s" "$(tool_floor nvim)"'
assert_success
assert_eq 'printf tool_floor' "$TEST_OUTPUT" \
  'a substitution inside quotes still runs its command'

# An environment prefix is not the command; the word after it is.
run_capture reader commands <<<'PATH="$mason_bin:$PATH" run_nvim_phase 0 "Verifying"'
assert_success
assert_eq 'run_nvim_phase' "$TEST_OUTPUT" \
  'an assignment prefix is not the command it precedes'

# An array literal holds data, not commands, so its words must not read as
# calls: `local packages=(git jq)` does not run git.
run_capture reader commands <<<'local packages=(git jq)'
assert_success
assert_eq 'local' "$TEST_OUTPUT" 'the words of an array literal are not commands'

run_capture reader commands <<<'# commented_call
printf "quoted_call"
: '"'"'single_quoted_call'"'"''
assert_success
assert_eq 'printf' "$TEST_OUTPUT" \
  'a name in a comment or a string is not a call'

# --- A definition is not a brace on one particular line ---------------------

same_line='enforce() {
  tool_floor_check nvim
}'
next_line='enforce()
{
  tool_floor_check nvim
}'
one_line='enforce() { tool_floor_check nvim; }'
keyword='function enforce {
  tool_floor_check nvim
}'

for spelling in "$same_line" "$next_line" "$one_line" "$keyword"; do
  run_capture reader functions <<<"$spelling"
  assert_success
  assert_eq 'enforce' "$TEST_OUTPUT" \
    'every spelling of a definition defines the same function'

  # ...and the body belongs to the function in every spelling, so nothing in
  # it reads as code the file runs on load.
  run_capture reader outside <<<"$spelling"
  assert_success
  assert_eq '' "$TEST_OUTPUT" \
    'a function body is never load-time code, however the definition is written'
done

# A body is handed back as written rather than with its strings blanked: the
# callers read paths and annotations out of it.
run_capture reader bodies <<<'apply_local() { "$DOTFILES_ROOT/common/setup-local.sh" macos; }'
assert_success
assert_eq 'apply_local: "$DOTFILES_ROOT/common/setup-local.sh" macos;' "$TEST_OUTPUT" \
  'a one-line body keeps the text it was written with'

# A function closes at the brace matching its own indentation, not at the first
# one in column 0: this repository nests helper functions, and the nested
# helper's closing brace used to end the function that contains it, taking
# every line below out of the file with it.
run_capture reader spans <<<'outer() {
  inner() {
    :
  }
  inner
}
after'
assert_success
assert_eq 'outer 0 5' "$TEST_OUTPUT" \
  'the nested helper'"'"'s closing brace does not end the function around it'

run_capture reader outside <<<'outer() {
  inner() {
    :
  }
  inner
}
after'
assert_success
assert_eq 'after' "$TEST_OUTPUT" 'the code after a nested helper still runs on load'

# --- Shell the reader cannot read is refused, never guessed at --------------

run_capture reader functions <<<'broken() {
  tool_floor_check nvim
: never closed'
assert_failure
assert_contains "$TEST_OUTPUT" 'is never closed'

# `name()` with nothing after it is not a definition this reader recognises, and
# inventing a span for it would take every following line out of the file.
run_capture reader outside <<<'not_a_definition()
printf "still here"'
assert_success
assert_contains "$TEST_OUTPUT" 'still here'

# --- code_line drops the comment and nothing else ---------------------------

# Two validators needed the same thing and had started to write it twice: the
# text of a line with its comment gone, but its strings intact. strip_noise
# cannot answer that, because blanking quoted text is right for a command name
# and wrong for anything whose value lives in a string.

run_capture reader code <<<'path="$DOTFILES_ROOT/config"  # where it lives'
assert_success
assert_eq '[path="$DOTFILES_ROOT/config"  ]' "$TEST_OUTPUT" \
  'a variable read inside double quotes survives, and the comment goes'

# The empty string an omitted sub-flag is recorded as. Trimming or unquoting
# here would make it indistinguishable from a variable that was never set.
run_capture reader code <<<"ai_codex=''"
assert_success
assert_eq "[ai_codex='']" "$TEST_OUTPUT" 'an empty assignment is left exactly as written'

# `#` opens a comment only at the start of a word, which is what leaves
# parameter expansion and the argument count alone.
run_capture reader code <<<'printf "%s" "${name#prefix}" "$#"'
assert_success
assert_eq '[printf "%s" "${name#prefix}" "$#"]' "$TEST_OUTPUT" \
  'a hash inside an expansion opens no comment'

run_capture reader code <<<'# nothing but a comment'
assert_success
assert_eq '[]' "$TEST_OUTPUT" 'a comment line reads as no code at all'

# A `#` inside a string is text, not a comment opener.
run_capture reader code <<<'printf "%s\n" "count: #1"  # really a comment'
assert_success
assert_eq '[printf "%s\n" "count: #1"  ]' "$TEST_OUTPUT" \
  'a hash inside a string is kept and the real comment is dropped'

printf 'PASS: code_line strips the comment and leaves everything else\n'

printf 'Shared shell reader tests passed.\n'
