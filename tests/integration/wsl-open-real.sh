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
url_log="$test_root/urls"
powershell="$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"
mkdir -p "$windows_root" "$(dirname -- "$powershell")" \
  "$work_root/directory with spaces"
touch "$work_root/æøå-文件.txt"

# wsl-open invokes Explorer once per argument, so the log must accumulate.
# Real explorer.exe also exits nonzero even on success; mirror that here.
cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$EXPLORER_ARGUMENT_LOG"
exit 1
EOF
cat >"$powershell" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$DOTFILES_WSL_OPEN_URL" >>"$POWERSHELL_URL_LOG"
EOF
chmod +x "$windows_root/explorer.exe" "$powershell"
: >"$argument_log"
: >"$url_log"

url='https://example.invalid/path?q=one two'
EXPLORER_ARGUMENT_LOG="$argument_log" POWERSHELL_URL_LOG="$url_log" \
  WINDOWS_SYSTEM_ROOT="$windows_root" \
  "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-open" \
  "$work_root/æøå-文件.txt" "$work_root/directory with spaces" "$url"

mapfile -d '' -t actual <"$argument_log"
expected_file="$(wslpath -w "$work_root/æøå-文件.txt")"
expected_directory="$(wslpath -w "$work_root/directory with spaces")"
[[ "${#actual[@]}" -eq 2 ]]
[[ "${actual[0]}" == "$expected_file" ]]
[[ "${actual[1]}" == "$expected_directory" ]]
mapfile -d '' -t urls <"$url_log"
[[ "${#urls[@]}" -eq 1 && "${urls[0]}" == "$url" ]]

# wsl-open hands a URL to Windows through WSLENV rather than a command line.
# Prove on real WSL interop that real Windows PowerShell reads it back intact.
real_powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
login_url='https://example.invalid/authorize?code=true&client_id=a%2Fb&state="x y"'
# $env: belongs to PowerShell.
# shellcheck disable=SC2016
seen_url="$(DOTFILES_WSL_OPEN_URL="$login_url" \
  WSLENV="DOTFILES_WSL_OPEN_URL${WSLENV:+:$WSLENV}" \
  "$real_powershell" -NoLogo -NoProfile -NonInteractive -Command \
  '[Console]::Out.Write($env:DOTFILES_WSL_OPEN_URL)' </dev/null)"
[[ "$seen_url" == "$login_url" ]] || {
  printf 'Windows PowerShell read %q, expected %q\n' "$seen_url" "$login_url" >&2
  exit 1
}

printf 'Real WSL path conversion boundary passed.\n'
