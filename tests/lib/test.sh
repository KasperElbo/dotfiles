#!/usr/bin/env bash

# Small, auditable shell-test support library. Test entrypoints select their
# own shell policy; sourcing this file intentionally does not change options.

TEST_ROOTS=()
TEST_OUTPUT=""
TEST_STATUS=0

_test_die() {
  printf 'TEST FAILURE: %s\n' "$*" >&2
  return 1
}

test_new_root() {
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")" || return 1
  TEST_ROOTS+=("$root")
  mkdir -p "$root"/{home,config,data,state,cache,bin,logs,contracts}
  printf '%s\n' "$root"
}

test_cleanup() {
  local root
  for root in "${TEST_ROOTS[@]}"; do
    [[ -n "$root" ]] && rm -rf -- "$root"
  done
  TEST_ROOTS=()
}

test_install_cleanup_trap() {
  trap test_cleanup EXIT INT TERM
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

assert_path_exists() {
  [[ -e "$1" || -L "$1" ]] || _test_die "expected path to exist: $1"
}

assert_path_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || _test_die "expected path to be absent: $1"
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
  mkdir -p "$root/bin" "$root/logs" "$root/contracts"

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
  exit 0
fi
printf 'strict stub rejected unsupported argv: %s%s%s\n' \
  "$name" "${invocation:+ }" "$invocation" >&2
exit 96
STUB
  chmod +x "$root/bin/.dotfiles-strict-stub"
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
