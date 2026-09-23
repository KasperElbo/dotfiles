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

# --- A line is read in the context of the lines before it ------------------

# The reader used to read each line on its own, so it had no idea a line was
# the body of a heredoc or the second line of a string. Help text listing a
# reader's name was reported as a call, and so were the heredoc's terminator
# and the first word of every line of it (#508, V4-04).
run_capture reader commands <<<'usage() {
  cat <<'"'"'EOF'"'"'
Usage: enforce.sh
tool_floor_check nvim   check the Neovim floor by hand
EOF
}
usage'
assert_success
assert_eq 'cat usage' "$TEST_OUTPUT" 'a quoted heredoc body is data, and so is its terminator'

run_capture reader commands <<<'cat <<EOF
tool_floor_check nvim
EOF
after'
assert_success
assert_eq 'after cat' "$TEST_OUTPUT" 'an unquoted heredoc body is data too'

# The subtle part of the same rule: an unquoted heredoc still expands `$( )`,
# so a command substituted into it does run. A quoted one expands nothing.
run_capture reader commands <<<'cat <<EOF
Floor: $(tool_floor nvim)
EOF'
assert_success
assert_eq 'cat tool_floor' "$TEST_OUTPUT" 'a substitution in an unquoted heredoc runs'

run_capture reader commands <<<'cat <<"EOF"
Floor: $(tool_floor nvim)
EOF'
assert_success
assert_eq 'cat' "$TEST_OUTPUT" 'nothing in a quoted heredoc runs'

run_capture reader commands <<<"$(printf 'if true; then\n\tcat <<-EOF\n\ttool_floor_check nvim\n\tEOF\nfi\nafter')"
assert_success
assert_eq 'after cat true' "$TEST_OUTPUT" 'a <<- heredoc ends at its tab-indented terminator'

run_capture reader commands <<<'grep -q x <<<"$value"
after'
assert_success
assert_eq 'after grep' "$TEST_OUTPUT" 'a here-string is not a heredoc'

run_capture reader commands <<<'shifted=$(( 1 << 2 ))
after'
assert_success
assert_eq 'after' "$TEST_OUTPUT" 'a shift inside arithmetic is not a heredoc'

run_capture reader commands <<<'printf "%s\n" "Checks:
tool_floor_check nvim
done"'
assert_success
assert_eq 'printf' "$TEST_OUTPUT" 'the second line of a string is still the string'

run_capture reader commands <<<'echo "an escaped \" quote does not close it"
after'
assert_success
assert_eq 'after echo' "$TEST_OUTPUT" 'an escaped quote leaves the string open to its real end'

run_capture reader commands <<<'value="$(
  tool_floor nvim
)"'
assert_success
assert_eq 'tool_floor' "$TEST_OUTPUT" 'a substitution that spans lines still runs its command'

run_capture reader commands <<<'echo \
  tool_floor_check nvim'
assert_success
assert_eq 'echo' "$TEST_OUTPUT" 'the word after a backslash-newline is an argument'

# A case arm's pattern sits where a command would, first on its line or after
# the `|` of the pattern before it, and is compared rather than run.
run_capture reader commands <<<'case "$1" in
  tool_floor_check) run_arm ;;
  --help | tool_floor) run_other ;;
  (other) run_third ;;
esac'
assert_success
assert_eq 'run_arm run_other run_third' "$TEST_OUTPUT" 'case patterns are not commands'

run_capture reader commands <<<'case "$a" in
  outer)
    case "$b" in inner) run_inner ;; esac
    run_outer ;;
  last) run_last ;;
esac'
assert_success
assert_eq 'run_inner run_last run_outer' "$TEST_OUTPUT" \
  'a nested case keeps the outer case reading its patterns'

run_capture reader code <<<'cat <<EOF
# kept: a heredoc line is text, not a comment
EOF'
assert_success
assert_eq '[cat <<EOF
# kept: a heredoc line is text, not a comment
EOF]' "$TEST_OUTPUT" 'a # inside a heredoc body opens no comment'

# --- A definition is found whatever its body is written in -----------------

# `name() ( ... )` runs its body in a subshell and is as much a definition as
# the braced form; it used to be read as load-time code (#508, V4-08).
run_capture reader functions <<<'in_subshell() (
  tool_floor_check nvim
)
after'
assert_success
assert_eq 'in_subshell' "$TEST_OUTPUT" 'a subshell body is a function'

run_capture reader outside <<<'in_subshell() (
  tool_floor_check nvim
)
after'
assert_success
assert_eq 'after' "$TEST_OUTPUT" 'and its body does not run on load'

# A comment after the closing brace still closes the function. It used to be
# compared as raw text, so the span ran on to the next brace and the function
# between them vanished.
run_capture reader spans <<<'first() {
  one
} # first
second() {
  two
}'
assert_success
assert_eq 'first 0 2
second 3 5' "$TEST_OUTPUT" 'a commented closing brace closes its own function'

run_capture reader spans <<<'writes_unit() {
  cat <<EOF
}
EOF
}
after() { :; }'
assert_success
assert_eq 'writes_unit 0 4
after 5 5' "$TEST_OUTPUT" 'a brace inside a heredoc closes nothing'

# --- Shell the reader cannot read is refused, never guessed at --------------

run_capture reader functions <<<'broken() {
  tool_floor_check nvim
: never closed'
assert_failure
assert_contains "$TEST_OUTPUT" 'is never closed'

# Text that ends inside a heredoc, a string or a case statement would be read
# with its quoting inverted from there on, so it is refused the same way.
run_capture reader commands <<<'cat <<EOF
tool_floor_check nvim'
assert_failure
assert_contains "$TEST_OUTPUT" "heredoc (terminator 'EOF') opened on line 1 is never closed"

run_capture reader commands <<<'echo "never closed
tool_floor_check nvim'
assert_failure
assert_contains "$TEST_OUTPUT" 'double-quoted string opened on line 1 is never closed'

run_capture reader commands <<<'case "$1" in
  a) tool_floor_check nvim ;;'
assert_failure
assert_contains "$TEST_OUTPUT" "never closed by 'esac'"

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
