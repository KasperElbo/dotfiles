#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

run_capture env \
  HOME="$root/home" \
  XDG_CONFIG_HOME="$root/config" \
  XDG_DATA_HOME="$root/data" \
  XDG_STATE_HOME="$root/state" \
  XDG_CACHE_HOME="$root/cache" \
  "$repo_root/common/install-ai.sh" --dry-run --firstmate
assert_success
assert_contains "$TEST_OUTPUT" "$root/data/firstmate/config/backend"
assert_contains "$TEST_OUTPUT" "to 'herdr'"
assert_contains "$TEST_OUTPUT" "without an FM_BACKEND prefix"

assert_file_contains "$repo_root/common/install-ai.sh" \
  'firstmate_backend_file="$firstmate_dir/config/backend"'
assert_file_contains "$repo_root/common/install-ai.sh" \
  'printf '\''herdr\n'\'' | atomic_write_file "$firstmate_backend_file"'

printf 'PASS: FirstMate installation defaults its local runtime backend to Herdr\n'
