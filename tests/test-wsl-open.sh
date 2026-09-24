#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"
windows_root="$test_root/windows"
work_root="$test_root/work"
argument_log="$test_root/explorer-arguments"
url_log="$test_root/powershell-urls"
wslpath_log="$test_root/wslpath-arguments"
powershell="$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"
mkdir -p "$windows_root" "$(dirname -- "$powershell")" "$work_root/bin" \
  "$work_root/directory with spaces"

cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$EXPLORER_ARGUMENT_LOG"
EOF
cat >"$work_root/bin/wslpath" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -w && $# -eq 2 ]] || exit 90
printf '%s\0' "$2" >>"$WSLPATH_ARGUMENT_LOG"
printf 'C:\\converted\\%s\n' "${2##*/}"
EOF
# The PowerShell stand-in records the URL the way Windows would see it: only
# variables WSLENV names cross into a Windows process, and the command must
# read the URL from one of them rather than from its own command line.
cat >"$powershell" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *'Start-Process -FilePath $env:DOTFILES_WSL_OPEN_URL'* ]] || exit 91
[[ ":$WSLENV:" == *:DOTFILES_WSL_OPEN_URL:* ]] || exit 92
[[ -n "${POWERSHELL_EXIT:-}" ]] && exit "$POWERSHELL_EXIT"
printf '%s\0' "$DOTFILES_WSL_OPEN_URL" >>"$POWERSHELL_URL_LOG"
EOF
chmod +x "$windows_root/explorer.exe" "$work_root/bin/wslpath" "$powershell"

touch "$work_root/file.txt"
touch "$work_root/directory with spaces/spaced file.txt"
touch "$work_root/æøå-文件.txt"
touch "$work_root/http"

run_open() {
  : >"$argument_log"
  : >"$url_log"
  : >"$wslpath_log"
  EXPLORER_ARGUMENT_LOG="$argument_log" \
    POWERSHELL_URL_LOG="$url_log" \
    WSLPATH_ARGUMENT_LOG="$wslpath_log" \
    WINDOWS_SYSTEM_ROOT="$windows_root" \
    PATH="$work_root/bin:$PATH" \
    "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-open" "$@"
}

assert_logged_arguments() {
  local path="$1"
  shift
  mapfile -d '' -t actual <"$path"
  assert_eq "$#" "${#actual[@]}" "argument count for $path"
  local index=0
  for expected in "$@"; do
    assert_eq "$expected" "${actual[index]}" "argument $index for $path"
    index=$((index + 1))
  done
}

run_open "$work_root/file.txt"
assert_logged_arguments "$argument_log" 'C:\converted\file.txt'
assert_logged_arguments "$wslpath_log" "$work_root/file.txt"

: >"$wslpath_log"
run_open "$work_root/directory with spaces"
assert_logged_arguments "$argument_log" 'C:\converted\directory with spaces'
assert_logged_arguments "$wslpath_log" "$work_root/directory with spaces"

: >"$wslpath_log"
(
  cd -- "$work_root"
  run_open './file.txt'
)
assert_logged_arguments "$argument_log" 'C:\converted\file.txt'
assert_logged_arguments "$wslpath_log" "$work_root/file.txt"

: >"$wslpath_log"
run_open "$work_root/directory with spaces/spaced file.txt"
assert_logged_arguments "$argument_log" 'C:\converted\spaced file.txt'
assert_logged_arguments "$wslpath_log" "$work_root/directory with spaces/spaced file.txt"

: >"$wslpath_log"
run_open "$work_root/æøå-文件.txt"
assert_logged_arguments "$argument_log" 'C:\converted\æøå-文件.txt'
assert_logged_arguments "$wslpath_log" "$work_root/æøå-文件.txt"

: >"$wslpath_log"
(
  cd -- "$work_root"
  run_open http
)
assert_logged_arguments "$argument_log" 'C:\converted\http'
assert_logged_arguments "$wslpath_log" "$work_root/http"

: >"$wslpath_log"
url='https://example.invalid/path?q=one two'
run_open "$url"
assert_logged_arguments "$url_log" "$url"
assert_file_empty "$argument_log"
assert_file_empty "$wslpath_log"

# A URL never goes to Explorer. Handed Claude Code's OAuth login link through
# the BROWSER this profile sets, explorer.exe opened a File Explorer window
# instead of the browser. Every character of the link must reach Windows.
login_url='https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=Ab-_c&state="x y"'
run_open "$login_url"
assert_logged_arguments "$url_log" "$login_url"
assert_file_empty "$argument_log"

WSLENV='EXISTING/p' run_open "$login_url"
assert_logged_arguments "$url_log" "$login_url"

run_open "$work_root/file.txt" "$url" "$work_root/directory with spaces"
assert_logged_arguments "$argument_log" \
  'C:\converted\file.txt' 'C:\converted\directory with spaces'
assert_logged_arguments "$url_log" "$url"
assert_logged_arguments "$wslpath_log" \
  "$work_root/file.txt" "$work_root/directory with spaces"

# Start-Process fails when Windows cannot open the URL, and that failure is the
# caller's to see: Claude Code prints the link for copying only when its
# opener exits nonzero.
POWERSHELL_EXIT=1 run_capture run_open "$url"
assert_failure
assert_contains "$TEST_OUTPUT" "Windows could not open URL: $url"

# A URL needs PowerShell, not Explorer, and is refused by name without it.
mv "$powershell" "$powershell.away"
run_capture run_open "$url"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "Windows PowerShell executable not found: $powershell"
assert_file_empty "$argument_log"
mv "$powershell.away" "$powershell"

: >"$argument_log"
: >"$wslpath_log"
run_capture run_open "$work_root/missing.txt"
assert_failure
assert_contains "$TEST_OUTPUT" "Path does not exist: $work_root/missing.txt"
assert_file_empty "$argument_log"
assert_file_empty "$wslpath_log"

run_capture run_open 'custom-scheme:value'
assert_failure
assert_contains "$TEST_OUTPUT" 'Unsupported URI or nonexistent path: custom-scheme:value'
assert_file_empty "$argument_log"
assert_file_empty "$url_log"

# Real explorer.exe exits nonzero even when it opens the target. Every argument
# must still be dispatched, and wsl-open must not inherit that status.
cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$EXPLORER_ARGUMENT_LOG"
exit 1
EOF
chmod +x "$windows_root/explorer.exe"

: >"$wslpath_log"
run_open "$work_root/file.txt" "$url" "$work_root/directory with spaces"
assert_logged_arguments "$argument_log" \
  'C:\converted\file.txt' 'C:\converted\directory with spaces'
assert_logged_arguments "$url_log" "$url"

# Interop off is a state this repository deliberately moves toward, and it is
# what a user hits when /etc/wsl.conf disables it or the Windows mount is not
# there: explorer.exe is simply absent. wsl-open refuses with a message naming
# the path it looked for, rather than letting the dispatch loop's `|| true`
# swallow a "command not found" and report success.
rm -f "$windows_root/explorer.exe"
run_capture run_open "$work_root/file.txt"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "Windows Explorer executable not found: $windows_root/explorer.exe"
assert_file_empty "$argument_log"
assert_file_empty "$wslpath_log"

# The same refusal is about being executable, not about existing: a mount
# without the execute bit is the other half of the same state.
cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$EXPLORER_ARGUMENT_LOG"
EOF
chmod -x "$windows_root/explorer.exe"
run_capture run_open "$work_root/file.txt"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "Windows Explorer executable not found: $windows_root/explorer.exe"
assert_file_empty "$argument_log"
assert_file_empty "$wslpath_log"

chmod +x "$windows_root/explorer.exe"

printf 'WSL path conversion and argument-boundary tests passed.\n'
