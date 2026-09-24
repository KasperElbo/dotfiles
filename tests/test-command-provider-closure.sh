#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

python3 "$repo_root/scripts/validate-command-provider-closure.py"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

duplicate_manifest="$test_root/duplicate.tsv"
cp "$repo_root/config/command-providers.tsv" "$duplicate_manifest"
duplicate_row="$(sed -n '2p' "$duplicate_manifest")"
printf '%s\n' "$duplicate_row" >>"$duplicate_manifest"
run_capture env COMMAND_PROVIDER_MANIFEST="$duplicate_manifest" \
  python3 "$repo_root/scripts/validate-command-provider-closure.py"
assert_failure
assert_contains "$TEST_OUTPUT" "has more than one provider"

wrong_owner_manifest="$test_root/wrong-owner.tsv"
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "jq" {$4="sway"} {print}' \
  "$repo_root/config/command-providers.tsv" >"$wrong_owner_manifest"
run_capture env COMMAND_PROVIDER_MANIFEST="$wrong_owner_manifest" \
  python3 "$repo_root/scripts/validate-command-provider-closure.py"
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
COMMAND_PROVIDER_MANIFEST="$missing_manifest"
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

# Every bash platform, not only Fedora, reads its pre-mutation commands from
# the manifest, so a missing command is reported with its provider there too.
for platform in macos parrot-ctf; do
  cat >"$missing_manifest" <<EOF
platform	command	provider	owner	required_by	classification
$platform	dotfiles-command-that-must-not-exist	dotfiles-prerequisite-package	base	base	supported-base
EOF
  run_capture preflight_platform_command_providers "$platform"
  assert_failure
  assert_contains "$TEST_OUTPUT" \
    'Missing supported-base command: dotfiles-command-that-must-not-exist (provider: dotfiles-prerequisite-package)'
done

# Dropping a platform's rows must fail validation naming the platform, rather
# than leaving its installer to fail closed only on the machine it targets.
no_macos_manifest="$test_root/no-macos.tsv"
awk -F '\t' '$1 != "macos"' "$repo_root/config/command-providers.tsv" >"$no_macos_manifest"
run_capture env COMMAND_PROVIDER_MANIFEST="$no_macos_manifest" \
  python3 "$repo_root/scripts/validate-command-provider-closure.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'platform missing from command provider manifest: macos'

# No installer states its own pre-mutation command list: each one checks its
# manifest rows and nothing else. preflight_commands was the literal-list helper
# the manifest replaced, so a call to it anywhere is a list the closure
# validator cannot see.
assert_registry_backed_preflight() {
  local tree="$1" installer platform relative status=0
  for installer in "$tree"/platforms/*/install.sh; do
    platform="$(basename "$(dirname "$installer")")"
    relative="${installer#"$tree/"}"
    if grep -Eq '(^|[^[:alnum:]_])preflight_commands([^[:alnum:]_]|$)' "$installer"; then
      printf '%s states its own preflight command list; declare those commands in config/command-providers.tsv instead.\n' \
        "$relative"
      status=1
    fi
    code_grep -Fq "preflight_platform_command_providers $platform" "$installer" || {
      printf '%s never checks its config/command-providers.tsv rows.\n' "$relative"
      status=1
    }
  done
  return "$status"
}
run_capture assert_registry_backed_preflight "$repo_root"
assert_success

literal_tree="$test_root/literal-preflight"
for installer in "$repo_root"/platforms/*/install.sh; do
  relative="${installer#"$repo_root/"}"
  mkdir -p "$literal_tree/$(dirname "$relative")"
  cp "$installer" "$literal_tree/$relative"
done
sed -i 's/^  preflight_platform_command_providers parrot-ctf$/  preflight_commands apt-get awk date find git readlink sudo systemctl/' \
  "$literal_tree/platforms/parrot-ctf/install.sh"
run_capture assert_registry_backed_preflight "$literal_tree"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'platforms/parrot-ctf/install.sh states its own preflight command list'
assert_contains "$TEST_OUTPUT" \
  'platforms/parrot-ctf/install.sh never checks its config/command-providers.tsv rows.'
assert_not_contains "$TEST_OUTPUT" 'platforms/macos/install.sh'

printf 'Command-provider closure tests passed.\n'
