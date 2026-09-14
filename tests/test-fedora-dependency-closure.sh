#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

python3 "$repo_root/scripts/validate-fedora-dependency-closure.py"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

duplicate_manifest="$test_root/duplicate.tsv"
cp "$repo_root/config/fedora-command-providers.tsv" "$duplicate_manifest"
duplicate_row="$(sed -n '2p' "$duplicate_manifest")"
printf '%s\n' "$duplicate_row" >>"$duplicate_manifest"
run_capture env FEDORA_COMMAND_PROVIDER_MANIFEST="$duplicate_manifest" \
  python3 "$repo_root/scripts/validate-fedora-dependency-closure.py"
assert_failure
assert_contains "$TEST_OUTPUT" "has more than one provider"

wrong_owner_manifest="$test_root/wrong-owner.tsv"
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "jq" {$4="sway"} {print}' \
  "$repo_root/config/fedora-command-providers.tsv" >"$wrong_owner_manifest"
run_capture env FEDORA_COMMAND_PROVIDER_MANIFEST="$wrong_owner_manifest" \
  python3 "$repo_root/scripts/validate-fedora-dependency-closure.py"
assert_failure
assert_contains "$TEST_OUTPUT" "provider 'jq' must be owned exactly once by sway; owners=base"

missing_manifest="$test_root/missing.tsv"
cat >"$missing_manifest" <<'EOF'
platform	command	provider	owner	required_by	classification
fedora	dotfiles-command-that-must-not-exist	dotfiles-prerequisite-package	base	base	bootstrap-prerequisite
EOF

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/capabilities.sh
source "$repo_root/common/lib/capabilities.sh"
# shellcheck source=../common/lib/preflight.sh
source "$repo_root/common/lib/preflight.sh"
FEDORA_COMMAND_PROVIDER_MANIFEST="$missing_manifest"
run_capture preflight_platform_command_providers fedora
assert_failure
assert_contains "$TEST_OUTPUT" \
  'Missing bootstrap-prerequisite command: dotfiles-command-that-must-not-exist (provider: dotfiles-prerequisite-package)'

# A platform key that does not match the manifest must fail closed rather than
# silently running zero pre-mutation checks.
run_capture preflight_platform_command_providers fedora-not-a-platform
assert_failure
assert_contains "$TEST_OUTPUT" \
  'No preflight command specification for platform: fedora-not-a-platform'

printf 'Fedora and Fedora WSL command-provider closure tests passed.\n'
