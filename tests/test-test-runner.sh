#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"
log="$root/runner.log"

make_suite() {
  local name="$1"
  local status="$2"
  local path="$root/$name.sh"
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
hung="$root/hang.sh"
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

printf 'Aggregate test-runner tests passed.\n'
