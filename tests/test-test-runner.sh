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

printf 'Aggregate test-runner tests passed.\n'
