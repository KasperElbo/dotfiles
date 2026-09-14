#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../../platforms/fedora-wsl/lib/wsl.sh
source "$repo_root/platforms/fedora-wsl/lib/wsl.sh"

require_fedora_wsl
require_command wslpath

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
windows_root="$test_root/windows"
work_root="$test_root/work"
argument_log="$test_root/arguments"
mkdir -p "$windows_root" "$work_root/directory with spaces"
touch "$work_root/æøå-文件.txt"

cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$EXPLORER_ARGUMENT_LOG"
EOF
chmod +x "$windows_root/explorer.exe"

url='https://example.invalid/path?q=one two'
EXPLORER_ARGUMENT_LOG="$argument_log" WINDOWS_SYSTEM_ROOT="$windows_root" \
  "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-open" \
  "$work_root/æøå-文件.txt" "$work_root/directory with spaces" "$url"

mapfile -d '' -t actual <"$argument_log"
expected_file="$(wslpath -w "$work_root/æøå-文件.txt")"
expected_directory="$(wslpath -w "$work_root/directory with spaces")"
[[ "${#actual[@]}" -eq 3 ]]
[[ "${actual[0]}" == "$expected_file" ]]
[[ "${actual[1]}" == "$expected_directory" ]]
[[ "${actual[2]}" == "$url" ]]

printf 'Real WSL path conversion boundary passed.\n'
