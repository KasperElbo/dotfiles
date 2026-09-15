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

printf 'Shared test-support tests passed.\n'
