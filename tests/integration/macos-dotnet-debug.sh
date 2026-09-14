#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$repo_root/tests/fixtures/dotnet-debug"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf 'This integration test requires native Apple Silicon macOS.\n' >&2
  exit 2
}

dotnet_command=(dotnet)
mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi
if [[ -n "$mise_command" ]] && "$mise_command" which dotnet >/dev/null 2>&1; then
  dotnet_command=("$mise_command" exec -- dotnet)
fi

dotnet_info="$("${dotnet_command[@]}" --info)"
printf '%s\n' "$dotnet_info"
grep -Eq 'Architecture:[[:space:]]+arm64' <<<"$dotnet_info" || {
  printf '.NET is not running as arm64.\n' >&2
  exit 1
}

easy_dotnet_version="$(
  sed -n 's/^"dotnet:EasyDotnet" = "\([^"]*\)"$/\1/p' \
    "$repo_root/mise/.config/mise/config.toml"
)"
[[ -n "$easy_dotnet_version" && "$easy_dotnet_version" != latest ]] || {
  printf 'EasyDotnet must be pinned for debugger-provider validation.\n' >&2
  exit 1
}

easy_dotnet_command=()
if [[ -n "$mise_command" ]] && "$mise_command" which dotnet-easydotnet >/dev/null 2>&1; then
  easy_dotnet_command=("$mise_command" exec -- dotnet-easydotnet)
elif command -v dotnet-easydotnet >/dev/null 2>&1; then
  easy_dotnet_command=(dotnet-easydotnet)
else
  tool_path="$test_root/tools"
  "${dotnet_command[@]}" tool install --tool-path "$tool_path" EasyDotnet --version "$easy_dotnet_version"
  easy_dotnet_command=("$tool_path/dotnet-easydotnet")
fi
health_json="$("${easy_dotnet_command[@]}" healthcheck --format json --debugger-engine netcoredbg)"
printf '%s\n' "$health_json"

read_health() {
  local name="$1"
  HEALTH_NAME="$name" python3 -c \
    'import json, os, sys; print(next(item["value"] for item in json.load(sys.stdin) if item["name"] == os.environ["HEALTH_NAME"]))' \
    <<<"$health_json"
}

debugger_engine="$(read_health debugger.engine)"
debugger_source="$(read_health debugger.source)"
debugger_platform="$(read_health debugger.platform)"
debugger_path="$(read_health debugger.path)"

[[ "$debugger_engine" == netcoredbg ]] || {
  printf 'EasyDotnet resolved debugger engine %s, expected netcoredbg.\n' "$debugger_engine" >&2
  exit 1
}
[[ "$debugger_source" == bundled && "$debugger_platform" == osx-arm64 ]] || {
  printf 'EasyDotnet resolved source/platform %s/%s, expected bundled/osx-arm64.\n' \
    "$debugger_source" "$debugger_platform" >&2
  exit 1
}
[[ "$debugger_path" == */tools/netcoredbg/osx-arm64/netcoredbg ]] || {
  printf 'EasyDotnet resolved an unexpected debugger path: %s\n' "$debugger_path" >&2
  exit 1
}
debugger_file="$(file -L "$debugger_path")"
printf '%s\n' "$debugger_file"
[[ "$debugger_file" == *arm64* || "$debugger_file" == *universal* ]] || {
  printf 'EasyDotnet debugger is not arm64/universal.\n' >&2
  exit 1
}

build_output="$test_root/build"
"${dotnet_command[@]}" build "$fixture/DebugSmoke.csproj" --configuration Debug --output "$build_output"
assembly="$build_output/DebugSmoke.dll"
python3 "$repo_root/tests/support/dap-smoke.py" \
  "$debugger_path" "$assembly" "$fixture/Program.cs"

rosetta_package=absent
if pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1; then
  rosetta_package=present
fi

legacy_archive="$test_root/netcoredbg-osx-amd64.tar.gz"
legacy_root="$test_root/legacy"
mkdir -p "$legacy_root"
curl --fail --location --silent --show-error \
  --output "$legacy_archive" \
  https://github.com/Samsung/netcoredbg/releases/download/3.1.3-1062/netcoredbg-osx-amd64.tar.gz
tar -xzf "$legacy_archive" -C "$legacy_root"
legacy_debugger="$(find "$legacy_root" -type f -name netcoredbg -perm -u+x -print -quit)"
[[ -n "$legacy_debugger" ]] || {
  printf 'The legacy x86_64 netcoredbg fixture was not extracted.\n' >&2
  exit 1
}
legacy_file="$(file -L "$legacy_debugger")"
printf '%s\n' "$legacy_file"
[[ "$legacy_file" == *x86_64* ]] || {
  printf 'The legacy debugger fixture is not x86_64.\n' >&2
  exit 1
}

legacy_start=failed
legacy_dap=not-run
if legacy_version="$($legacy_debugger --version 2>&1)"; then
  legacy_start=succeeded
  printf 'Legacy x86_64 start: %s\n' "$legacy_version"
  if python3 "$repo_root/tests/support/dap-smoke.py" \
    "$legacy_debugger" "$assembly" "$fixture/Program.cs" --timeout 15; then
    legacy_dap=succeeded
  else
    legacy_dap=failed
  fi
else
  printf 'Legacy x86_64 start failed: %s\n' "$legacy_version"
fi

printf 'Rosetta package: %s\nLegacy x86_64 start: %s\nLegacy x86_64 -> arm64 DAP: %s\n' \
  "$rosetta_package" "$legacy_start" "$legacy_dap"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  summary_dotnet="$(printf '\\140dotnet\\140')"
  summary_platform="$(printf '\\140osx-arm64\\140')"
  summary_value="$(printf '\\140value == 42\\140')"
  {
    printf '## Apple Silicon .NET debugger evidence\n\n'
    printf -- '- %s: arm64\n' "$summary_dotnet"
    printf -- '- selected provider: EasyDotnet bundled netcoredbg (%s)\n' "$summary_platform"
    printf -- '- native breakpoint/evaluate interaction: passed (%s)\n' "$summary_value"
    printf -- '- Rosetta package: %s\n' "$rosetta_package"
    printf -- '- legacy x86_64 binary start: %s\n' "$legacy_start"
    printf -- '- legacy x86_64 debugger -> native arm64 CoreCLR: %s\n' "$legacy_dap"
  } >>"$GITHUB_STEP_SUMMARY"
fi
