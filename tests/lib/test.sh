#!/usr/bin/env bash

# Small, auditable shell-test support library. Test entrypoints select their
# own shell policy; sourcing this file intentionally does not change options.

TEST_ROOTS=()
# Isolated PATH directories are not test roots: they must stay resolvable for
# the whole suite, so only the exit trap removes them, after everything else.
TEST_PATH_ROOTS=()
TEST_ROOT=""
TEST_OUTPUT=""
TEST_STATUS=0
# Every failed assertion in this shell, whatever the suite's shell policy.
TEST_FAILURES=0
TEST_EXIT_HOOK=""

# Assertions count the failure and still return 1, so an errexit suite aborts
# at the first one and the exit trap fails any suite that carried on.
_test_die() {
  TEST_FAILURES=$((TEST_FAILURES + 1))
  printf 'TEST FAILURE: %s\n' "$*" >&2
  return 1
}

test_new_root() {
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")" || return 1
  TEST_ROOTS+=("$root")
  TEST_ROOT="$root"
  mkdir -p "$root"/{home,config,data,state,cache,bin,logs,contracts,handlers}
}

test_cleanup() {
  local root
  for root in "${TEST_ROOTS[@]}"; do
    [[ -n "$root" ]] && rm -rf -- "$root"
  done
  TEST_ROOTS=()
  # Public state is consumed by scripts sourcing this library.
  # shellcheck disable=SC2034
  TEST_ROOT=""
}

# test_install_cleanup_trap [hook]: on exit, run the optional suite-owned hook
# (for example restoring a tracked file a negative case edited in place), remove
# every test root, and fail the suite if any assertion failed.
#
# The failure check is what makes an assertion binding on a suite that runs
# without errexit, swallows an assertion status, or ends on an unrelated
# command that succeeds. Give extra cleanup to the hook; a replacement EXIT
# trap would drop the check.
test_install_cleanup_trap() {
  TEST_EXIT_HOOK="${1:-}"
  trap _test_exit_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

_test_exit_trap() {
  local status=$?
  if [[ -n "$TEST_EXIT_HOOK" ]]; then
    "$TEST_EXIT_HOOK"
  fi
  test_cleanup
  # Last, and in one rm: these directories hold rm itself.
  if ((${#TEST_PATH_ROOTS[@]} > 0)); then
    rm -rf -- "${TEST_PATH_ROOTS[@]}"
  fi
  if ((status == 0 && TEST_FAILURES > 0)); then
    printf 'TEST FAILURE: %d failed assertion(s); failing a suite that would have exited 0\n' \
      "$TEST_FAILURES" >&2
    exit 1
  fi
}

# Host commands every isolated suite may resolve: the portable part of the
# supported-base commands in config/command-providers.tsv plus the basic
# userland the suites themselves use, all present on both the pinned Fedora
# validation image and macOS. Anything else a suite needs from the host, such as
# git, jq, zsh or the Linux-only getent, is named explicitly by that suite.
TEST_HOST_COMMANDS=(
  awk basename bash cat chmod comm cp cut date dirname echo env find grep head id
  install ln ls mkdir mktemp mv paste pwd readlink realpath rm rmdir sed sh
  sleep sort stat sync tail tee touch tr uname uniq wc xargs
)

# df is deliberately not in that list. It was, and linking the host's df into
# every isolated PATH made the disk preflight answer from the free space of the
# machine running the tests. Four suites then carried a byte-identical roomy-df
# heredoc to undo it, and RA-33 had to add that copy in three separate review
# rounds because a different suite was missed each time. Left out, a suite that
# reaches preflight_disk_space without stubbing df fails deterministically with
# "Could not determine the free disk space" instead of depending on the host.
# Suites that want the roomy figure call test_stub_roomy_df; a suite that wants
# the real df names it in its own test_isolate_path call.

# test_isolate_path [command ...]: replace PATH with one directory that links
# only TEST_HOST_COMMANDS and the named commands, resolved from the current
# PATH.
#
# Without this, a tool installed on the machine running the tests (a real
# opam, mise or tailscale, or a workstation PATH full of agents) satisfies a
# lookup the suite meant to mock or to find absent, and the same suite passes in
# CI and fails on a workstation. Suites put their mocks in front, as in
# PATH="$mock_bin:$PATH", and never append /usr/bin or /bin. A missing host
# command is a test failure, never a silently narrower PATH. bash links to the
# running interpreter so `#!/usr/bin/env bash` scripts run under the suite's
# own Bash.
test_isolate_path() {
  local bin name resolved
  bin="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test-path.XXXXXX")" || return 1
  TEST_PATH_ROOTS+=("$bin")
  for name in "${TEST_HOST_COMMANDS[@]}" "$@"; do
    if [[ "$name" == bash ]]; then
      resolved="$BASH"
    else
      resolved="$(type -P -- "$name")" ||
        _test_die "test_isolate_path: host command not found on PATH: $name" ||
        return 1
    fi
    ln -sf -- "$resolved" "$bin/$name" || return 1
  done
  export PATH="$bin"
}

test_env_args() {
  local root="$1"
  printf '%s\n' \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "XDG_DATA_HOME=$root/data" \
    "XDG_STATE_HOME=$root/state" \
    "XDG_CACHE_HOME=$root/cache"
}

run_capture() {
  TEST_OUTPUT=""
  TEST_STATUS=0
  if TEST_OUTPUT="$("$@" 2>&1)"; then
    TEST_STATUS=0
  else
    TEST_STATUS=$?
  fi
  return 0
}

assert_status() {
  local expected="$1"
  local actual="${2:-$TEST_STATUS}"
  [[ "$actual" == "$expected" ]] ||
    _test_die "expected status $expected, got $actual${TEST_OUTPUT:+; output: $TEST_OUTPUT}"
}

assert_success() {
  assert_status 0 "${1:-$TEST_STATUS}"
}

assert_failure() {
  local actual="${1:-$TEST_STATUS}"
  [[ "$actual" -ne 0 ]] ||
    _test_die "expected non-zero status, got 0${TEST_OUTPUT:+; output: $TEST_OUTPUT}"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="${3:-values differ}"
  [[ "$actual" == "$expected" ]] ||
    _test_die "$context: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] ||
    _test_die "expected output to contain '$needle':\n$haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] ||
    _test_die "expected output not to contain '$needle':\n$haystack"
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  [[ -r "$path" ]] || _test_die "file is not readable: $path" || return 1
  grep -Fq -- "$needle" "$path" ||
    _test_die "expected $path to contain '$needle'"
}

assert_file_line() {
  local path="$1"
  local expected="$2"
  [[ -r "$path" ]] || _test_die "file is not readable: $path" || return 1
  grep -Fxq -- "$expected" "$path" ||
    _test_die "expected $path to contain exact line '$expected'"
}

assert_file_not_contains() {
  local path="$1"
  local needle="$2"
  # A missing file used to pass here, alone among the file assertions. That
  # makes every negative assertion in the suites survive a rename of the file
  # it guards, with nothing to say it stopped checking.
  [[ -r "$path" ]] || _test_die "file is not readable: $path" || return 1
  if grep -Fq -- "$needle" "$path"; then
    _test_die "expected $path not to contain '$needle'"
  fi
}

# files_identical <first> <second>: byte comparison without diffutils.
#
# The Fedora validation container ships no cmp or diff, and a missing tool must
# never be reported as a difference. This reads both files in full and compares
# them, with a sentinel so a trailing newline cannot be lost to command
# substitution. Text only: Bash cannot hold NUL bytes.
files_identical() {
  local first="$1" second="$2" first_content second_content

  [[ -f "$first" && -f "$second" ]] || return 1
  first_content="$(
    cat -- "$first"
    printf end
  )" || return 1
  second_content="$(
    cat -- "$second"
    printf end
  )" || return 1
  [[ "$first_content" == "$second_content" ]]
}

assert_files_identical() {
  local first="$1" second="$2"
  files_identical "$first" "$second" ||
    _test_die "expected identical file contents: $first and $second"
}

assert_file_empty() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ ! -s "$path" ]] || _test_die "expected file to be empty: $path"
}

assert_path_exists() {
  [[ -e "$1" || -L "$1" ]] || _test_die "expected path to exist: $1"
}

assert_path_executable() {
  [[ -x "$1" ]] || _test_die "expected executable path: $1"
}

assert_path_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || _test_die "expected path to be absent: $1"
}

# ---------------------------------------------------------------------------
# Verifier outcomes
# ---------------------------------------------------------------------------

# verifier_failure_lines <output>: the failure lines a verifier printed, with
# the colour escapes and the leading ✗ removed, one per line. The marker is
# written literally rather than as a \x escape, which only GNU sed reads.
verifier_failure_lines() {
  sed $'s/\033\\[[0-9;]*m//g' <<<"$1" | sed -n 's/^✗ //p'
}

# assert_verifier_failures <output> [prefix ...]: the run failed exactly the
# checks named here, and nothing else. No prefix means no check may fail.
#
# A fixture that cannot reach a clean run -- the macOS one describes no Mac, so
# some sections fail in it whatever the tree does -- used to be held to the
# *number* of failures it produced. A count is an open assertion: a check added
# to the verifier that fails on every run raises the baseline by one, every
# case measured against that baseline still passes, and nothing anywhere says
# the new check has never once succeeded. Naming the set closes it. The count
# follows from the list, so a case may still compare against it.
#
# Each prefix must begin exactly one failure line, and every failure line must
# be begun by exactly one prefix. A prefix short enough to cover two failures
# is the same open assertion in miniature, so it is reported rather than
# quietly accepted. Prefixes rather than whole lines because a verifier names
# the paths it looked at, and those carry the fixture's temporary root.
assert_verifier_failures() {
  local output="$1"
  shift
  # Namespaced locals: ShellCheck reads this library into every suite that
  # sources it, so a plain name here is a name collision there.
  local -a verify_declared=() verify_reported=()
  local verify_line verify_d verify_r verify_hits verify_report=''

  for verify_line in "$@"; do
    verify_declared+=("$verify_line")
  done
  while IFS= read -r verify_line; do
    [[ -n "$verify_line" ]] || continue
    verify_reported+=("$verify_line")
  done < <(verifier_failure_lines "$output")

  for ((verify_d = 0; verify_d < ${#verify_declared[@]}; verify_d++)); do
    verify_hits=0
    for ((verify_r = 0; verify_r < ${#verify_reported[@]}; verify_r++)); do
      [[ "${verify_reported[verify_r]}" == "${verify_declared[verify_d]}"* ]] &&
        verify_hits=$((verify_hits + 1))
    done
    ((verify_hits == 1)) && continue
    if ((verify_hits == 0)); then
      verify_report="$verify_report"$'\n'"  declared, never reported: ${verify_declared[verify_d]}"
    else
      verify_report="$verify_report"$'\n'"  declared, covers $verify_hits failures: ${verify_declared[verify_d]}"
    fi
  done

  for ((verify_r = 0; verify_r < ${#verify_reported[@]}; verify_r++)); do
    verify_hits=0
    for ((verify_d = 0; verify_d < ${#verify_declared[@]}; verify_d++)); do
      [[ "${verify_reported[verify_r]}" == "${verify_declared[verify_d]}"* ]] &&
        verify_hits=$((verify_hits + 1))
    done
    ((verify_hits == 1)) && continue
    if ((verify_hits == 0)); then
      verify_report="$verify_report"$'\n'"  reported, never declared: ${verify_reported[verify_r]}"
    else
      verify_report="$verify_report"$'\n'"  reported, covered $verify_hits times: ${verify_reported[verify_r]}"
    fi
  done

  [[ -z "$verify_report" ]] ||
    _test_die "the verifier failed a different set of checks than the one declared:$verify_report"
}

# ---------------------------------------------------------------------------
# Strict command contracts
# ---------------------------------------------------------------------------
#
# Stubs are explicit allow-lists. test_stub_allow records one exact argv vector;
# the generated command logs every invocation before accepting or rejecting it.
# This is intentionally less convenient than an unconditional-success fake:
# unexpected privileged/package/service calls must fail tests.

_test_stub_quote_argv() {
  local argument quoted="" part
  for argument in "$@"; do
    printf -v part '%q' "$argument"
    quoted="${quoted}${quoted:+ }$part"
  done
  printf '%s\n' "$quoted"
}

test_stub_init() {
  local root="$1"
  export TEST_STUB_ROOT="$root"
  mkdir -p "$root/bin" "$root/logs" "$root/contracts" "$root/handlers"

  cat >"$root/bin/.dotfiles-strict-stub" <<'STUB'
#!/usr/bin/env bash
set -u
name="${0##*/}"
root="${TEST_STUB_ROOT:?TEST_STUB_ROOT is required}"
log="$root/logs/$name.log"
contract="$root/contracts/$name.allow"

quote_argv() {
  local argument quoted="" part
  for argument in "$@"; do
    printf -v part '%q' "$argument"
    quoted="${quoted}${quoted:+ }$part"
  done
  printf '%s\n' "$quoted"
}

invocation="$(quote_argv "$@")"
printf '%s\n' "$invocation" >>"$log"
if [[ -r "$contract" ]] && grep -Fxq -- "$invocation" "$contract"; then
  handler="$root/handlers/$name"
  if [[ -x "$handler" ]]; then
    exec "$handler" "$@"
  fi
  exit 0
fi
printf 'strict stub rejected unsupported argv: %s%s%s\n' \
  "$name" "${invocation:+ }" "$invocation" >&2
exit 96
STUB
  chmod +x "$root/bin/.dotfiles-strict-stub"
}

# test_stub_roomy_df <bin-dir>: install a df reporting plenty of free space.
#
# The disk preflight then decides on a known figure rather than on whatever the
# machine running the tests happens to have free. Suites that mean to exercise a
# full disk write their own df over this one and call this again to restore it.
test_stub_roomy_df() {
  local bin="$1"
  cat >"$bin/df" <<'EOF_ROOMY_DF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/roomy-volume 102400000 20480000 81920000 20%% /\n'
EOF_ROOMY_DF
  chmod +x "$bin/df"
}

# test_stub_npm_global <bin>: an `npm` reporting the global prefix named by
# TEST_NPM_GLOBAL_PREFIX and exactly the packages listed in
# TEST_NPM_GLOBAL_PACKAGES, space separated and empty for none.
#
# The AI verifier rules out an AI package duplicated in the active Node prefix.
# Without this stub that question is answered by whatever global npm the host
# happens to have, so a developer machine or a CI image carrying a global
# @anthropic-ai/claude-code would fail suites that are about something else --
# the same silent host dependency `df` had before it was stubbed. A suite that
# wants the duplicate detected sets TEST_NPM_GLOBAL_PACKAGES instead of
# unstubbing.
test_stub_npm_global() {
  local bin="$1"
  cat >"$bin/npm" <<'EOF_NPM_GLOBAL'
#!/usr/bin/env bash
set -u
prefix="${TEST_NPM_GLOBAL_PREFIX:-/test/npm-prefix}"
case "$*" in
"ls --global --depth=0 --parseable")
  printf '%s/lib\n' "$prefix"
  for package in ${TEST_NPM_GLOBAL_PACKAGES:-}; do
    printf '%s/lib/node_modules/%s\n' "$prefix" "$package"
  done
  ;;
"prefix --global") printf '%s\n' "$prefix" ;;
*)
  printf 'strict npm fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
  ;;
esac
# npm reports a dependency problem in the tree through its exit status while
# still printing the tree, so TEST_NPM_GLOBAL_STATUS is set independently of
# what was listed above.
exit "${TEST_NPM_GLOBAL_STATUS:-0}"
EOF_NPM_GLOBAL
  chmod +x "$bin/npm"
}

test_stub_install() {
  local root="$1"
  local name="$2"
  [[ -x "$root/bin/.dotfiles-strict-stub" ]] || test_stub_init "$root"
  ln -sf .dotfiles-strict-stub "$root/bin/$name"
  : >"$root/logs/$name.log"
  : >"$root/contracts/$name.allow"
}

test_stub_allow() {
  local root="$1"
  local name="$2"
  shift 2
  _test_stub_quote_argv "$@" >>"$root/contracts/$name.allow"
}

test_stub_log() {
  local root="$1"
  local name="$2"
  cat "$root/logs/$name.log"
}

test_stub_assert_called() {
  local root="$1"
  local name="$2"
  shift 2
  local expected
  expected="$(_test_stub_quote_argv "$@")"
  grep -Fxq -- "$expected" "$root/logs/$name.log" ||
    _test_die "expected $name argv '$expected'; log follows:\n$(cat "$root/logs/$name.log" 2>/dev/null || true)"
}
