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

printf 'Shared test-support tests passed.\n'
