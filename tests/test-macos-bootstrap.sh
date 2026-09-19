#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

assert_contains() {
  local value="$1"
  local expected="$2"
  [[ "$value" == *"$expected"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$expected" "$value" >&2
    exit 1
  }
}

# The public entry point remains useful for help and dry-run when invoked via
# the exact system-Bash command used on a fresh Mac.
help_output="$(/bin/bash "$repo_root/install.sh" --platform macos --help)"
assert_contains "$help_output" 'Usage: ./install.sh [--platform NAME|--platform=NAME] [options]'
assert_contains "$help_output" '--dry-run'

dry_run_output="$(/bin/bash "$repo_root/install.sh" --platform macos --dry-run \
  --theme mocha --no-ocaml --no-containers --no-tailscale --no-defaults \
  --non-interactive)"
assert_contains "$dry_run_output" 'No changes were made.'

# A disposable real-installer fixture records NUL-delimited arguments. This
# proves re-exec forwards the original vector rather than a joined string.
fixture_root="$test_root/fixture"
mkdir -p "$fixture_root/scripts" "$fixture_root/platforms/macos"
cp "$repo_root/install.sh" "$fixture_root/install.sh"
cp "$repo_root/scripts/bootstrap-macos.sh" "$fixture_root/scripts/bootstrap-macos.sh"
cp "$repo_root/platforms/macos/bootstrap-help.txt" "$fixture_root/platforms/macos/bootstrap-help.txt"
cat >"$fixture_root/scripts/install-main.sh" <<'EOF_FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$BASH_VERSION" >"$CAPTURE_VERSION"
: >"$CAPTURE_ARGS"
for argument in "$@"; do
  printf '%s\0' "$argument" >>"$CAPTURE_ARGS"
done
EOF_FIXTURE
chmod +x "$fixture_root/install.sh" "$fixture_root/scripts/bootstrap-macos.sh" \
  "$fixture_root/scripts/install-main.sh"

capture_args="$test_root/args"
capture_version="$test_root/version"
CAPTURE_ARGS="$capture_args" CAPTURE_VERSION="$capture_version" \
  /bin/bash "$fixture_root/install.sh" --platform macos \
  --theme 'some value' --foo value --foo second-value
python3 - "$capture_args" <<'PY'
import pathlib
import sys

actual = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
if actual[-1:] == [b""]:
    actual.pop()
expected = [
    b"--platform", b"macos", b"--theme", b"some value",
    b"--foo", b"value", b"--foo", b"second-value",
]
assert actual == expected, (actual, expected)
PY
python3 - "$capture_version" <<'PY'
import pathlib
import sys

major, minor, *_ = pathlib.Path(sys.argv[1]).read_text().split(".")
assert (int(major), int(minor)) >= (4, 4), (major, minor)
PY

# No optional arguments is a separate zero-length forwarding case after the
# dispatcher consumes the platform selector.
CAPTURE_ARGS="$capture_args" CAPTURE_VERSION="$capture_version" \
  /bin/bash "$fixture_root/install.sh" --platform macos
python3 - "$capture_args" <<'PY'
import pathlib
import sys

actual = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
if actual[-1:] == [b""]:
    actual.pop()
assert actual == [b"--platform", b"macos"], actual
PY

# Current main already replaced the old empty system_args/verify_args arrays.
# Exercise both zero-argument branches behaviorally so nounset cannot regress.
fake_root="$test_root/fake-root"
mkdir -p "$fake_root/platforms/macos/scripts"
action_log="$test_root/actions.log"
cat >"$fake_root/platforms/macos/scripts/install-system.sh" <<'EOF_FIXTURE'
#!/usr/bin/env bash
printf 'system:%s' "$#" >>"$ACTION_LOG"
for argument in "$@"; do printf ':%s' "$argument" >>"$ACTION_LOG"; done
printf '\n' >>"$ACTION_LOG"
EOF_FIXTURE
cat >"$fake_root/platforms/macos/scripts/verify.sh" <<'EOF_FIXTURE'
#!/usr/bin/env bash
printf 'verify:%s' "$#" >>"$ACTION_LOG"
for argument in "$@"; do printf ':%s' "$argument" >>"$ACTION_LOG"; done
printf '\n' >>"$ACTION_LOG"
EOF_FIXTURE
chmod +x "$fake_root/platforms/macos/scripts/install-system.sh" \
  "$fake_root/platforms/macos/scripts/verify.sh"

DOTFILES_ROOT="$fake_root"
ACTION_LOG="$action_log"
export DOTFILES_ROOT ACTION_LOG
activate_homebrew_path() { :; }
# shellcheck source=../platforms/macos/lib/install-actions.sh
source "$repo_root/platforms/macos/lib/install-actions.sh"
macos_run_system_installer true
macos_run_system_installer false
macos_run_verifier false false false false
macos_run_verifier true true true true
# The optional-profile arguments are independent, and an omitted fourth one
# still means "not selected" rather than an unbound variable.
macos_run_verifier true false true
grep -Fxq 'system:0' "$action_log"
grep -Fxq 'system:1:--non-interactive' "$action_log"
grep -Fxq 'verify:0' "$action_log"
grep -Fxq 'verify:4:--defaults:--containers:--tailscale:--dictation' "$action_log"
grep -Fxq 'verify:2:--defaults:--tailscale' "$action_log"

if [[ "$(uname -s)" == Darwin ]]; then
  # Force explicit Homebrew discovery while ordinary PATH lookup can see only
  # Apple system tools. The modern-only real boundary proves re-exec happened.
  trace="$test_root/trace"
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOMEBREW_BIN=/opt/homebrew/bin/brew DOTFILES_BOOTSTRAP_TRACE=true \
    /bin/bash "$repo_root/install.sh" --platform macos --help \
    >"$test_root/system-help" 2>"$trace"
  grep -Fq 'macOS bootstrap: re-executing with /opt/homebrew/' "$trace"
  grep -Fq -- '--dry-run' "$test_root/system-help"

  if /bin/bash "$repo_root/scripts/install-main.sh" --platform macos --help \
    >"$test_root/old-real" 2>&1; then
    printf 'The real installer unexpectedly accepted Apple system Bash.\n' >&2
    exit 1
  fi
  grep -Fq 'real installer requires Bash 4.4 or newer' "$test_root/old-real"

  if /bin/bash "$repo_root/platforms/macos/install.sh" --help \
    >"$test_root/old-platform" 2>&1; then
    printf 'The direct macOS installer unexpectedly accepted Apple system Bash.\n' >&2
    exit 1
  fi
  grep -Fq 'Start it through ./install.sh --platform macos' "$test_root/old-platform"

  # Missing Homebrew/Bash remains mutation-free for help and dry-run. Apply is
  # the explicit route that may establish them before lifecycle state begins.
  HOMEBREW_BIN="$test_root/missing-brew" /bin/bash "$repo_root/install.sh" \
    --platform macos --dry-run --theme mocha >"$test_root/bootstrap-plan"
  grep -Fq 'Homebrew:             would be installed' "$test_root/bootstrap-plan"
  grep -Fq 'No changes were made.' "$test_root/bootstrap-plan"
fi

printf 'macOS system-Bash bootstrap, argv, and empty-argument checks passed.\n'
