#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail_test() {
  printf '.NET debugger contract test failed: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/verify.sh
source "$repo_root/common/lib/verify.sh"

dotnet_config="$repo_root/nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua"
mason_inventory="$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"
mise_config="$repo_root/mise/.config/mise/config.toml"

grep -Fq 'engine = "netcoredbg"' "$dotnet_config" ||
  fail_test "easy-dotnet.nvim does not select the bundled netcoredbg engine"
if grep -Fq 'bin_path' "$dotnet_config" || grep -Fq 'LazyVim.get_pkg_path' "$dotnet_config"; then
  fail_test "easy-dotnet.nvim still permits the Mason debugger to override the bundled provider"
fi
if grep -Fxq netcoredbg "$mason_inventory"; then
  fail_test "netcoredbg is still declared in the Mason inventory"
fi
grep -Fq '"dotnet:EasyDotnet" = "3.4.25"' "$mise_config" ||
  fail_test "EasyDotnet is not pinned to the release that bundles native osx-arm64 netcoredbg"

for platform in fedora fedora-wsl macos; do
  awk -F '\t' -v platform="$platform" \
    '$1 == "dotnet-debug" && $2 == platform && $8 == "mise-easydotnet" && $15 == "implemented" { found = 1 } END { exit !found }' \
    "$repo_root/config/capabilities.tsv" ||
    fail_test "$platform does not declare the EasyDotnet debugger provider"
done

for installer in platforms/fedora/install.sh platforms/fedora-wsl/install.sh platforms/macos/install.sh; do
  grep -Fq 'local selected=(base dotnet-debug)' "$repo_root/$installer" ||
    fail_test "$installer does not select the supported debugger capability during preflight"
  grep -Fq 'capabilities=base,dotnet-debug' "$repo_root/$installer" ||
    fail_test "$installer does not record the supported debugger capability in lifecycle state"
done
for verifier in platforms/fedora/scripts/verify.sh platforms/fedora-wsl/scripts/verify.sh platforms/macos/scripts/verify.sh; do
  grep -Fq 'check_easy_dotnet_debugger' "$repo_root/$verifier" ||
    fail_test "$verifier does not verify the EasyDotnet debugger provider"
done

mock_bin="$test_root/bin"
debugger_root="$test_root/store/easydotnet/tools/netcoredbg"
mkdir -p "$mock_bin" "$debugger_root/osx-arm64"
touch "$debugger_root/osx-arm64/netcoredbg"
chmod +x "$debugger_root/osx-arm64/netcoredbg"

cat >"$mock_bin/dotnet-easydotnet" <<'EOF_MOCK'
#!/usr/bin/env bash
[[ "$*" == "healthcheck --format json --debugger-engine netcoredbg" ]] || exit 91
printf '%s\n' "$MOCK_EASY_DOTNET_HEALTH"
EOF_MOCK
chmod +x "$mock_bin/dotnet-easydotnet"
PATH="$mock_bin:$PATH"
export PATH

health_json() {
  local source="$1" platform="$2" path="$3" version_type="${4:-ok}"
  local version="${5:-NET Core debugger test version}"
  printf '[{"type":"ok","name":"debugger.engine","value":"netcoredbg"},{"type":"ok","name":"debugger.source","value":"%s"},{"type":"ok","name":"debugger.platform","value":"%s"},{"type":"ok","name":"debugger.path","value":"%s"},{"type":"%s","name":"debugger.version","value":"%s"}]\n' \
    "$source" "$platform" "$path" "$version_type" "$version"
}

verify_reset
MOCK_EASY_DOTNET_HEALTH="$(health_json bundled osx-arm64 "$debugger_root/osx-arm64/netcoredbg")"
export MOCK_EASY_DOTNET_HEALTH
check_easy_dotnet_debugger osx-arm64 >/dev/null
[[ "$VERIFY_FAILURES" == 0 ]] || fail_test "the native bundled provider was rejected"
[[ "$EASY_DOTNET_DEBUGGER_PATH" == "$debugger_root/osx-arm64/netcoredbg" ]] ||
  fail_test "the resolved EasyDotnet debugger path was not exposed to the caller"

mkdir -p "$test_root/nvim/mason/packages/netcoredbg/libexec/netcoredbg"
mason_debugger="$test_root/nvim/mason/packages/netcoredbg/libexec/netcoredbg/netcoredbg"
touch "$mason_debugger"
chmod +x "$mason_debugger"
verify_reset
MOCK_EASY_DOTNET_HEALTH="$(health_json --debugger-bin-path osx-arm64 "$mason_debugger")"
export MOCK_EASY_DOTNET_HEALTH
if check_easy_dotnet_debugger osx-arm64 >/dev/null; then :; fi
((VERIFY_FAILURES >= 2)) || fail_test "a custom/Mason debugger path was accepted"

verify_reset
MOCK_EASY_DOTNET_HEALTH="$(health_json bundled osx-x64 "$debugger_root/osx-arm64/netcoredbg")"
export MOCK_EASY_DOTNET_HEALTH
if check_easy_dotnet_debugger osx-arm64 >/dev/null; then :; fi
((VERIFY_FAILURES >= 1)) || fail_test "the wrong bundled platform was accepted"

failing_debugger="$test_root/failing/tools/netcoredbg/osx-arm64/netcoredbg"
mkdir -p "$(dirname "$failing_debugger")"
cat >"$failing_debugger" <<'EOF_DEBUGGER'
#!/usr/bin/env bash
exit 1
EOF_DEBUGGER
chmod +x "$failing_debugger"
verify_reset
MOCK_EASY_DOTNET_HEALTH="$(
  health_json bundled osx-arm64 "$failing_debugger" warn \
    'netcoredbg --version exited with status 1'
)"
export MOCK_EASY_DOTNET_HEALTH
if check_easy_dotnet_debugger osx-arm64 >/dev/null; then :; fi
((VERIFY_FAILURES >= 1)) || fail_test "a debugger that cannot start was accepted"

printf '.NET debugger provider contract passed.\n'
