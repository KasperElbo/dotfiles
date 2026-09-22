#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"
test_stub_init "$root"

for name in sudo dnf apt-get systemctl git curl mise; do
  test_stub_install "$root" "$name"
done

path="$root/bin:$PATH"

printf 'Strict sudo argv logging\n'
test_stub_allow "$root" sudo --non-interactive systemctl restart sshd.service
run_capture env TEST_STUB_ROOT="$root" PATH="$path" sudo --non-interactive systemctl restart sshd.service
assert_success
assert_eq '--non-interactive systemctl restart sshd.service' "$(test_stub_log "$root" sudo)" \
  'sudo must log exact argv'

run_capture env TEST_STUB_ROOT="$root" PATH="$path" sudo rm -rf /unexpected
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict stub rejected unsupported argv: sudo'

printf 'Strict package-manager argv\n'
test_stub_allow "$root" dnf --assumeyes install git
run_capture env TEST_STUB_ROOT="$root" PATH="$path" dnf --assumeyes install git
assert_success
run_capture env TEST_STUB_ROOT="$root" PATH="$path" dnf --assumeyes --skip-broken install git
assert_status 96
assert_contains "$TEST_OUTPUT" 'strict stub rejected unsupported argv: dnf'

test_stub_allow "$root" apt-get update
run_capture env TEST_STUB_ROOT="$root" PATH="$path" apt-get update
assert_success
run_capture env TEST_STUB_ROOT="$root" PATH="$path" apt-get --allow-unauthenticated update
assert_status 96

printf 'System and user systemd scopes are distinct\n'
test_stub_allow "$root" systemctl is-active --quiet sshd.service
run_capture env TEST_STUB_ROOT="$root" PATH="$path" systemctl is-active --quiet sshd.service
assert_success
run_capture env TEST_STUB_ROOT="$root" PATH="$path" systemctl --user is-active --quiet sshd.service
assert_status 96

test_stub_allow "$root" systemctl --user is-active --quiet pipewire.service
run_capture env TEST_STUB_ROOT="$root" PATH="$path" systemctl --user is-active --quiet pipewire.service
assert_success
run_capture env TEST_STUB_ROOT="$root" PATH="$path" systemctl is-active --quiet pipewire.service
assert_status 96

printf 'Other reusable stubs reject unspecified argv\n'
for command_name in git curl mise; do
  run_capture env TEST_STUB_ROOT="$root" PATH="$path" "$command_name" unexpected
  assert_status 96
  assert_contains "$TEST_OUTPUT" "strict stub rejected unsupported argv: $command_name"
done

printf 'Allowed commands may use suite-local state handlers\n'
cat >"$root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_STUB_ROOT/state/systemctl-handler"
exit 23
EOF
chmod +x "$root/handlers/systemctl"
test_stub_allow "$root" systemctl restart handler-test.service
run_capture env TEST_STUB_ROOT="$root" PATH="$path" \
  systemctl restart handler-test.service
assert_status 23
assert_file_line "$root/state/systemctl-handler" 'restart handler-test.service'
run_capture env TEST_STUB_ROOT="$root" PATH="$path" \
  systemctl stop handler-test.service
assert_status 96

# --- A failed assertion always fails the suite ------------------------------

# run_suite <shell options> <body>: a throwaway suite in a child bash that
# sources the library and installs its exit trap, as a real suite does.
run_suite() {
  local options="$1" body="$2"
  run_capture bash -c "
    set $options
    source \"\$1/tests/lib/test.sh\"
    test_install_cleanup_trap
    $body
  " _ "$repo_root"
}

printf 'A failed assertion fails a suite that runs without errexit\n'
run_suite '-uo pipefail' 'assert_eq expected actual "negative control"
printf "suite reached its end\n"'
assert_status 1
assert_contains "$TEST_OUTPUT" 'TEST FAILURE: negative control'
assert_contains "$TEST_OUTPUT" 'suite reached its end'
assert_contains "$TEST_OUTPUT" '1 failed assertion(s)'

printf 'A swallowed assertion status still fails the suite\n'
run_suite '-euo pipefail' 'assert_eq expected actual "negative control" || true
printf "suite reached its end\n"'
assert_status 1
assert_contains "$TEST_OUTPUT" 'suite reached its end'

printf 'Under errexit an assertion still aborts at the first failure\n'
run_suite '-euo pipefail' 'assert_eq expected actual "negative control"
printf "suite reached its end\n"'
assert_status 1
assert_not_contains "$TEST_OUTPUT" 'suite reached its end'

printf 'A passing suite exits 0 and a suite-chosen status is kept\n'
run_suite '-euo pipefail' 'assert_eq same same'
assert_status 0
assert_not_contains "$TEST_OUTPUT" 'TEST FAILURE'
run_suite '-uo pipefail' 'assert_eq expected actual "negative control"
exit 7'
assert_status 7

printf 'The exit hook runs before the test roots are removed\n'
run_suite '-euo pipefail' 'restore() { [[ -d "$TEST_ROOT" ]] && printf "hook saw %s\n" "$TEST_ROOT"; }
test_install_cleanup_trap restore
test_new_root
printf "%s\n" "$TEST_ROOT"'
assert_status 0
suite_root="$(head -n1 <<<"$TEST_OUTPUT")"
assert_contains "$TEST_OUTPUT" "hook saw $suite_root"
assert_path_missing "$suite_root"

printf 'An isolated PATH exposes only the base and named host commands\n'
host_bin="$root/host-bin"
mkdir -p "$host_bin"
for command_name in dotfiles-named-tool dotfiles-unnamed-tool; do
  printf '#!/bin/sh\nexit 0\n' >"$host_bin/$command_name"
  chmod +x "$host_bin/$command_name"
done
run_capture env PATH="$host_bin:$PATH" bash -c '
  set -euo pipefail
  source "$1/tests/lib/test.sh"
  test_install_cleanup_trap
  test_isolate_path dotfiles-named-tool
  printf "isolated=%s\n" "$PATH"
  command -v dotfiles-named-tool >/dev/null && printf "named tool visible\n"
  command -v dotfiles-unnamed-tool >/dev/null || printf "unnamed tool hidden\n"
  [[ "$(command -v bash)" -ef "$BASH" ]] && printf "bash is the running interpreter\n"
  test_new_root
  test_cleanup
  [[ -x "$PATH/rm" ]] && printf "isolated PATH survives test_cleanup\n"
' _ "$repo_root"
assert_status 0
assert_contains "$TEST_OUTPUT" 'named tool visible'
assert_contains "$TEST_OUTPUT" 'unnamed tool hidden'
assert_contains "$TEST_OUTPUT" 'bash is the running interpreter'
assert_contains "$TEST_OUTPUT" 'isolated PATH survives test_cleanup'
isolated_path="$(sed -n 's/^isolated=//p' <<<"$TEST_OUTPUT")"
[[ "$isolated_path" == /* && "$isolated_path" != *:* ]] ||
  _test_die "expected one absolute isolated PATH directory, got '$isolated_path'"
assert_path_missing "$isolated_path"

printf 'A host command an isolated suite names but the runner lacks fails the suite\n'
run_capture bash -c '
  set -uo pipefail
  source "$1/tests/lib/test.sh"
  test_install_cleanup_trap
  test_isolate_path dotfiles-absent-tool || printf "helper returned failure\n"
  printf "suite reached its end\n"
' _ "$repo_root"
assert_status 1
assert_contains "$TEST_OUTPUT" 'host command not found on PATH: dotfiles-absent-tool'
assert_contains "$TEST_OUTPUT" 'helper returned failure'

printf 'Every suite that sources the library keeps its failure accumulator\n'
for suite in "$repo_root"/tests/test-*.sh; do
  grep -Fq 'source "$repo_root/tests/lib/test.sh"' "$suite" || continue
  assert_file_contains "$suite" 'test_install_cleanup_trap'
  # A suite-owned EXIT trap replaces the library's and drops the check; extra
  # cleanup belongs in the test_install_cleanup_trap hook instead.
  if grep -Eq '^[[:space:]]*trap[[:space:]].*EXIT' "$suite"; then
    _test_die "$suite installs its own EXIT trap; pass cleanup to test_install_cleanup_trap"
  fi
done

# --- No test pipes into a quiet grep ----------------------------------------

# `grep -q` exits at its first match, so the producer on the left of the pipe
# is left writing to a closed pipe: it takes SIGPIPE and exits non-zero, and
# under `set -o pipefail` that becomes the pipeline's status. The pipeline then
# reports on the writer rather than on the match, and it does so in exactly the
# case each assertion exists to detect. Both directions are unsound:
#
#   producer | grep -Fq needle || _test_die   fails when the needle IS present
#   if producer | grep -Fq needle; then ...   does nothing when it IS present
#
# The first fired once for real, in tests/test-action-registry.sh on a loaded
# machine, and blamed the sheet rather than the pipeline. The second is the
# worse of the two: it fails open, so an assertion written that way -- several
# of them negative controls proving a validator still catches drift -- passes
# silently while catching nothing. Both survive only while the producer is
# small enough to finish before grep exits, which is precisely the property
# that changes under load. So the rule is one rule: a test never pipes into a
# quiet grep, in either direction. Read the producer into a variable and match
# against a here-string.
printf 'No test pipes into a quiet grep\n'

# The defect first, because a rule is worth only as much as its demonstration:
# with a producer still writing when grep exits, a needle that IS present is
# reported absent, and the here-string form of the same test finds it.
#
# The producer waits rather than racing. A large-but-finite one -- `seq 1
# 200000` was the first attempt -- makes the proof depend on pipe buffer size
# and scheduling, and it duly found the needle on the macOS runner while
# failing open on Linux: the demonstration of a timing bug must not itself be
# one. Emitting the needle and then sleeping makes grep's early exit certain to
# leave the producer writing to a closed pipe, on every platform, while still
# terminating.
quiet_grep_proof="$root/quiet-grep-fails-open.sh"
cat >"$quiet_grep_proof" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
producer() {
  printf 'needle\n'
  sleep 1
  printf 'tail\n'
}
if producer | grep -Fq needle; then
  printf 'piped: FOUND\n'
else
  printf 'piped: NOT FOUND\n'
fi
haystack="$(producer)"
if grep -Fq needle <<<"$haystack"; then
  printf 'here-string: FOUND\n'
else
  printf 'here-string: NOT FOUND\n'
fi
EOF
run_capture bash "$quiet_grep_proof"
assert_success
assert_contains "$TEST_OUTPUT" 'piped: NOT FOUND'
assert_contains "$TEST_OUTPUT" 'here-string: FOUND'

quiet_grep_check="$repo_root/tests/support/check-quiet-grep-assertions.py"
run_capture python3 "$quiet_grep_check" "$repo_root"/tests/*.sh \
  "$repo_root"/tests/lib/*.sh "$repo_root"/tests/integration/*.sh
assert_success

# The negative control: both shapes, so a check that had stopped looking, or
# that had kept the old exemption for the failure-expected direction, fails
# here rather than passing quietly.
quiet_grep_control="$root/quiet-grep-control.sh"
cat >"$quiet_grep_control" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Line 4 fails closed: the assertion fails when the needle IS present.
list_installed_tools | grep -Fq 'ripgrep' || _test_die 'ripgrep must be installed'
# Line 6 fails open: the branch is skipped when the needle IS present.
if list_installed_tools | grep -Fq 'yabai'; then
  _test_die 'yabai must not be installed'
fi
# Line 10 is the fix, and must not be reported.
tools="$(list_installed_tools)"
grep -Fq 'ripgrep' <<<"$tools" || _test_die 'ripgrep must be installed'
EOF
run_capture python3 "$quiet_grep_check" "$quiet_grep_control"
assert_status 1
assert_contains "$TEST_OUTPUT" "$quiet_grep_control:4: pipes a producer into a quiet grep"
assert_contains "$TEST_OUTPUT" "$quiet_grep_control:6: pipes a producer into a quiet grep"
assert_not_contains "$TEST_OUTPUT" "$quiet_grep_control:11"

# A check that cannot read its input must say so rather than skip it.
quiet_grep_unreadable="$root/quiet-grep-unreadable.sh"
printf '#!/usr/bin/env bash\nprintf %s\n' "'unterminated" >"$quiet_grep_unreadable"
run_capture python3 "$quiet_grep_check" "$quiet_grep_unreadable"
assert_status 2
assert_contains "$TEST_OUTPUT" 'cannot read as shell'
assert_contains "$TEST_OUTPUT" 'unterminated single quote'

# --- A verifier's failures are a named set, not a count ---------------------

# verifier_fixture <path> [message ...]: a file holding what a verifier writes
# when those checks fail, marker and colour escapes and all, so these cases
# read the real shape rather than a hand-typed approximation of it.
verifier_fixture() {
  local path="$1" line
  shift
  : >"$path"
  for line in "$@"; do
    printf '\033[1;31m%s\033[0m %s\n' "✗" "$line" >>"$path"
  done
}

ghostty_failure='Ghostty is missing: /Applications/Ghostty.app'
ssh_failure='ssh resolves to /tmp/dotfiles-test.aaaaaa/bin/ssh, not /usr/bin/ssh'

printf 'A declared failure set accepts exactly the failures it names\n'
fixture="$root/verifier-declared.log"
verifier_fixture "$fixture" "$ghostty_failure" "$ssh_failure"
assert_verifier_failures "$(cat "$fixture")" 'Ghostty is missing: ' 'ssh resolves to '
assert_eq "$ghostty_failure" \
  "$(verifier_failure_lines "$(cat "$fixture")" | head -n 1)" \
  'the marker and the colour escapes are stripped'

printf 'A check that fails on every run is reported, not absorbed\n'
# The negative control for issue #371: one check more than the list describes,
# which a baseline count would have taken as the new normal.
verifier_fixture "$root/verifier-extra.log" "$ghostty_failure" 'a check that fails on every run'
run_suite '-uo pipefail' "assert_verifier_failures \"\$(cat $root/verifier-extra.log)\" 'Ghostty is missing: '"
assert_status 1
assert_contains "$TEST_OUTPUT" 'reported, never declared: a check that fails on every run'

printf 'A declared failure that stopped being reported is named\n'
verifier_fixture "$root/verifier-missing.log" "$ghostty_failure"
run_suite '-uo pipefail' "assert_verifier_failures \"\$(cat $root/verifier-missing.log)\" 'Ghostty is missing: ' 'AeroSpace is missing: '"
assert_status 1
assert_contains "$TEST_OUTPUT" 'declared, never reported: AeroSpace is missing: '

printf 'A prefix loose enough to cover two failures is refused\n'
# Otherwise the list reopens what it was written to close: one entry silently
# stands in for any number of failures that happen to start alike.
verifier_fixture "$root/verifier-loose.log" "$ghostty_failure" 'Ghostty is missing: its configuration'
run_suite '-uo pipefail' "assert_verifier_failures \"\$(cat $root/verifier-loose.log)\" 'Ghostty is missing: '"
assert_status 1
assert_contains "$TEST_OUTPUT" 'declared, covers 2 failures: Ghostty is missing: '

printf 'A run with no failures satisfies an empty declaration\n'
verifier_fixture "$root/verifier-clean.log"
assert_verifier_failures "$(cat "$root/verifier-clean.log")"
run_suite '-uo pipefail' "assert_verifier_failures \"\$(cat $root/verifier-extra.log)\""
assert_status 1
assert_contains "$TEST_OUTPUT" 'reported, never declared: a check that fails on every run'

printf 'Shared test-support tests passed.\n'
