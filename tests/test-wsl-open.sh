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
wslpath_log="$test_root/wslpath-arguments"
mkdir -p "$windows_root" "$work_root/bin" "$work_root/directory with spaces"

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
chmod +x "$windows_root/explorer.exe" "$work_root/bin/wslpath"

touch "$work_root/file.txt"
touch "$work_root/directory with spaces/spaced file.txt"
touch "$work_root/æøå-文件.txt"
touch "$work_root/http"

run_open() {
  EXPLORER_ARGUMENT_LOG="$argument_log" \
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
assert_logged_arguments "$argument_log" "$url"
assert_file_empty "$wslpath_log"

: >"$wslpath_log"
run_open "$work_root/file.txt" "$url" "$work_root/directory with spaces"
assert_logged_arguments "$argument_log" \
  'C:\converted\file.txt' "$url" 'C:\converted\directory with spaces'
assert_logged_arguments "$wslpath_log" \
  "$work_root/file.txt" "$work_root/directory with spaces"

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

printf 'WSL path conversion and argument-boundary tests passed.\n'
