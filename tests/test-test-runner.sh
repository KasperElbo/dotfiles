#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

# The runner now refuses any suite outside tests/, so this suite's fixtures
# live in a scratch directory inside tests/ rather than under $TEST_ROOT. The
# name is dot-prefixed and carries no `test-` prefix, so neither the shell glob
# in unregistered_suites below nor the repository's own suite discovery sees
# it, and the exit hook removes it however the suite ends.
remove_suite_dir() {
  [[ -n "${suite_dir:-}" ]] && rm -rf -- "$suite_dir"
}

test_install_cleanup_trap remove_suite_dir
test_new_root
root="$TEST_ROOT"
log="$root/runner.log"
suite_dir="$(mktemp -d "$repo_root/tests/.runner-fixtures.XXXXXX")"

make_suite() {
  local name="$1"
  local status="$2"
  local path="$suite_dir/$name.sh"
  cat >"$path" <<EOF_SUITE
#!/usr/bin/env bash
printf '%s\\n' '$name' >>"\${RUNNER_LOG:?}"
exit $status
EOF_SUITE
  chmod +x "$path"
  printf '%s\n' "$path"
}

pass_one="$(make_suite pass-one 0)"
fail_one="$(make_suite fail-one 23)"
pass_two="$(make_suite pass-two 0)"

printf 'Aggregate mode continues independent suites\n'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$pass_one" "$fail_one" "$pass_two"
assert_status 1
assert_file_contains "$log" 'pass-one'
assert_file_contains "$log" 'fail-one'
assert_file_contains "$log" 'pass-two'
assert_contains "$TEST_OUTPUT" 'passed:  2'
assert_contains "$TEST_OUTPUT" 'failed:  1'
assert_contains "$TEST_OUTPUT" 'skipped: 0'

printf 'Fail-fast mode stops and accounts for remaining suites\n'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" --fail-fast "$pass_one" "$fail_one" "$pass_two"
assert_status 1
assert_file_contains "$log" 'pass-one'
assert_file_contains "$log" 'fail-one'
assert_not_contains "$(cat "$log")" 'pass-two'
assert_contains "$TEST_OUTPUT" 'passed:  1'
assert_contains "$TEST_OUTPUT" 'failed:  1'
assert_contains "$TEST_OUTPUT" 'skipped: 1'
assert_contains "$TEST_OUTPUT" 'pass-two.sh (fail-fast)'

printf 'Missing explicit runner dependencies are errors\n'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=dotfiles-command-that-does-not-exist \
  RUNNER_LOG="$log" "$repo_root/scripts/test.sh" "$pass_one"
assert_status 2
assert_contains "$TEST_OUTPUT" 'missing required test dependencies: dotfiles-command-that-does-not-exist'
assert_eq '' "$(cat "$log")" 'dependency failure must happen before any suite executes'

printf 'Targeted mode does not require unrelated aggregate-only tools\n'
limited_bin="$root/targeted-bin"
mkdir -p "$limited_bin"
ln -s "$(command -v bash)" "$limited_bin/bash"
ln -s "$(command -v dirname)" "$limited_bin/dirname"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS= PATH="$limited_bin" RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$pass_one"
assert_status 0
assert_file_contains "$log" 'pass-one'
assert_contains "$TEST_OUTPUT" 'passed:  1'
assert_contains "$TEST_OUTPUT" 'failed:  0'

printf 'A dependency below its documented floor is a runner error\n'
floor_bin="$root/floor-bin"
mkdir -p "$floor_bin"
cat >"$floor_bin/nvim" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] || exit 0
printf 'NVIM v0.9.5\n'
EOF
chmod +x "$floor_bin/nvim"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=nvim PATH="$floor_bin:$PATH" \
  RUNNER_LOG="$log" "$repo_root/scripts/test.sh" "$pass_one"
assert_status 2
assert_contains "$TEST_OUTPUT" 'nvim 0.9.5 is older than the required 0.12'
assert_eq '' "$(cat "$log")" 'a floor failure must happen before any suite executes'

printf 'A floor manifest the runner cannot read is a runner error\n'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=nvim \
  TOOL_FLOOR_MANIFEST="$root/no-such-floors.tsv" \
  RUNNER_LOG="$log" "$repo_root/scripts/test.sh" "$pass_one"
assert_status 2
assert_contains "$TEST_OUTPUT" "could not read the version floors from $root/no-such-floors.tsv"
assert_eq '' "$(cat "$log")" 'an unreadable floor manifest must stop before any suite executes'

printf 'A floor manifest whose header lost the tool column is a runner error\n'
headerless="$root/headerless-floors.tsv"
printf 'name\tmin_version\trequirement\tconsumers\n' >"$headerless"
printf 'nvim\t0.12\tThe tracked configuration requires it\tscripts/test.sh\n' >>"$headerless"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=nvim \
  TOOL_FLOOR_MANIFEST="$headerless" \
  RUNNER_LOG="$log" "$repo_root/scripts/test.sh" "$pass_one"
assert_status 2
assert_contains "$TEST_OUTPUT" "has no column: tool"
assert_contains "$TEST_OUTPUT" "could not read the version floors from $headerless"
assert_eq '' "$(cat "$log")" 'a floor manifest without a tool column must stop before any suite executes'

printf 'The lazy.nvim checkout is resolved by one rule, shared with the suite that needs it\n'
# Two copies of this rule would be two chances for the runner to preflight a
# path the suite does not use, which is worse than not preflighting: the run
# would be refused for a checkout that is present, or admitted for one that is
# missing. Both callers source this file, so the rule is asserted once here.
# shellcheck source=lib/lazy-nvim.sh
source "$repo_root/tests/lib/lazy-nvim.sh"

assert_eq "$root/explicit" \
  "$(DOTFILES_LAZY_NVIM="$root/explicit" lazy_nvim_checkout)" \
  'DOTFILES_LAZY_NVIM names the checkout when it is set'
assert_eq "$root/xdg/nvim/lazy/lazy.nvim" \
  "$(DOTFILES_LAZY_NVIM='' XDG_DATA_HOME="$root/xdg" lazy_nvim_checkout)" \
  'otherwise the path a normal install leaves behind'

# `lua/lazy`, not the directory itself: an empty directory and a half-finished
# clone both satisfy a bare -d and then fail further in, talking about Lua.
bare_checkout="$root/bare-lazy"
mkdir -p "$bare_checkout"
lazy_nvim_is_ready "$bare_checkout" &&
  _test_die 'an empty directory was accepted as a lazy.nvim checkout'
mkdir -p "$bare_checkout/lua/lazy"
lazy_nvim_is_ready "$bare_checkout" ||
  _test_die 'a directory carrying lua/lazy was not accepted as a checkout'

printf 'A missing lazy.nvim checkout is a runner error, not a suite failure partway through\n'
# The defect: the preflight only understood names on PATH, so this requirement
# bypassed it and surfaced as one red suite in the middle of a long run on a
# machine that satisfied every documented tool. Bounded by `timeout`, because a
# regression here does not fail this case, it starts the whole aggregate run.
: >"$log"
run_capture env "DOTFILES_LAZY_NVIM=$root/no-such-lazy-checkout" RUNNER_LOG="$log" \
  timeout 120 "$repo_root/scripts/test.sh"
assert_status 2
assert_contains "$TEST_OUTPUT" 'no lazy.nvim checkout at'
assert_contains "$TEST_OUTPUT" "$root/no-such-lazy-checkout"
assert_contains "$TEST_OUTPUT" 'no suites were run or credited as skipped'
assert_not_contains "$TEST_OUTPUT" '==> tests/'
assert_eq '' "$(cat "$log")" 'the refusal must happen before any suite executes'

printf 'Targeted mode still runs without a lazy.nvim checkout\n'
# Each selected suite reports its own dependencies, and the Neovim suite's hard
# failure stays the backstop; refusing a targeted run over a checkout it does
# not need would be the same defect in the other direction.
: >"$log"
run_capture env "DOTFILES_LAZY_NVIM=$root/no-such-lazy-checkout" \
  DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$pass_one"
assert_status 0
assert_file_contains "$log" 'pass-one'

printf 'The run states how many suites it is about to run, read off the array\n'
# The count in circulation was 89 while the runner ran 82. A number quoted from
# memory is a coverage claim nothing checks, so the run prints its own.
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$pass_one" "$pass_two"
assert_status 0
assert_contains "$TEST_OUTPUT" 'Running 2 suites'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$pass_one"
assert_status 0
assert_contains "$TEST_OUTPUT" 'Running 1 suite'
assert_not_contains "$TEST_OUTPUT" 'Running 1 suites'

printf 'A suite that is not registered in default_tests is a build failure\n'
# Nothing used to require this. A new tests/test-*.sh that always failed passed
# every validator, because no check compared the directory with the runner's
# own list -- so a suite could be written, forgotten, and never run.
#
# The check is a function of a tests directory and a runner, so the same code
# answers for this repository and for a scratch directory that is deliberately
# missing one. `default_tests` is read out of the runner as the shell array it
# is, by the shell, rather than matched as text.
unregistered_suites() {
  local tests_dir="$1" runner="$2" suite name
  local -a default_tests=()
  # shellcheck disable=SC1090  # the array declaration, evaluated on its own.
  eval "$(sed -n '/^default_tests=(/,/^)/p' "$runner")"
  ((${#default_tests[@]} > 0)) || {
    printf 'no default_tests array in %s\n' "$runner"
    return
  }
  local registered
  registered="$(printf '%s\n' "${default_tests[@]}")"
  for suite in "$tests_dir"/test-*.sh; do
    [[ -e "$suite" ]] || continue
    name="tests/${suite##*/}"
    grep -Fxq "$name" <<<"$registered" ||
      printf '%s is not registered in default_tests in %s\n' "$name" "$runner"
  done
}

orphans="$(unregistered_suites "$repo_root/tests" "$repo_root/scripts/test.sh")"
assert_eq '' "$orphans" 'every tests/test-*.sh must be listed in default_tests'

# The negative control: a suite file the runner does not know about. It is
# written to a scratch directory, so this checkout never grows a stray suite.
orphan_dir="$root/orphan-tests"
mkdir -p "$orphan_dir"
cp "$repo_root/tests/test-verifier.sh" "$orphan_dir/test-verifier.sh"
# Composed rather than written out, so the hygiene suite's "every repository
# path a tracked file names must exist" rule does not read this fixture's name
# as a promise that tests/ holds such a file.
orphan_name="test-never-$(printf 'registered').sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$orphan_dir/$orphan_name"
orphans="$(unregistered_suites "$orphan_dir" "$repo_root/scripts/test.sh")"
assert_contains "$orphans" \
  "tests/$orphan_name is not registered in default_tests"
assert_not_contains "$orphans" 'test-verifier.sh is not registered'

printf 'A hung suite is killed and counted as failed, not left to stall the run\n'
hung="$suite_dir/hang.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" hang >>"${RUNNER_LOG:?}"\nsleep 120\n' >"$hung"
chmod +x "$hung"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash DOTFILES_TEST_SUITE_TIMEOUT=2 \
  RUNNER_LOG="$log" "$repo_root/scripts/test.sh" "$hung" "$pass_one"
assert_status 1
assert_file_contains "$log" 'hang'
assert_file_contains "$log" 'pass-one'
assert_contains "$TEST_OUTPUT" 'timed out after 2s'
assert_contains "$TEST_OUTPUT" 'failed:  1'
assert_contains "$TEST_OUTPUT" 'passed:  1'

printf 'A suite outside tests/ is refused before it can execute\n'
# SEC-01. The runner used to execute whatever path it was handed and count it
# as a passing suite, while this repository's .claude/settings.json pre-approves
# `./scripts/test.sh tests/...` -- which an agent matcher reads as a prefix, so
# a traversal out of tests/ ran arbitrary code with no permission prompt.
#
# The assertion is the sentinel, not the exit status: a refusal that still ran
# the file would exit non-zero for some other reason and read as a pass here.
outside="$root/outside-the-tree.sh"
sentinel="$root/outside-ran"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$sentinel" >"$outside"
chmod +x "$outside"

# Composed rather than resolved with realpath, which is not a declared runner
# dependency: one `..` per component of the path the runner will join the
# argument to, which lands on / and is then followed by the absolute fixture.
traversal="tests"
IFS='/' read -r -a suite_root_parts <<<"${repo_root#/}/tests"
for _ in "${suite_root_parts[@]}"; do
  traversal+="/.."
done
traversal+="$outside"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$traversal"
assert_status 1
assert_contains "$TEST_OUTPUT" "Refusing to run a suite outside tests/: $traversal"
assert_contains "$TEST_OUTPUT" 'passed:  0'
assert_eq 'absent' "$([[ -e "$sentinel" ]] && printf 'ran' || printf 'absent')" \
  'a refused suite must not execute'

printf 'An absolute path outside tests/ is refused the same way\n'
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$outside"
assert_status 1
assert_contains "$TEST_OUTPUT" "Refusing to run a suite outside tests/: $outside"
assert_contains "$TEST_OUTPUT" 'passed:  0'
assert_eq 'absent' "$([[ -e "$sentinel" ]] && printf 'ran' || printf 'absent')" \
  'a refused absolute suite must not execute'

printf 'A suite inside tests/ that is absent is still the missing-suite error\n'
# Containment must not swallow the case it sits in front of. The name is built
# from the fixture directory rather than written out, so the hygiene suite does
# not read a deliberately absent path as a promise that tests/ holds one.
absent="${suite_dir#"$repo_root/"}/never-written.sh"
: >"$log"
run_capture env DOTFILES_TEST_REQUIRED_COMMANDS=bash RUNNER_LOG="$log" \
  "$repo_root/scripts/test.sh" "$absent"
assert_status 1
assert_contains "$TEST_OUTPUT" "Missing test suite: $absent"
assert_not_contains "$TEST_OUTPUT" 'Refusing to run a suite'

printf 'Aggregate test-runner tests passed.\n'
