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

# Help that names no platform is answered for the machine asking. On a Mac the
# plain ./install.sh --help used to reach the real installer under Apple's
# Bash 3.2 and stop at its Bash 4.4 gate. A fake uname stands in for the
# kernel, so the routing is proved on every host; the system-Bash run below
# proves the reported command itself on a Mac.
help_root="$test_root/help-fixture"
help_capture="$test_root/help-route"
mkdir -p "$help_root/scripts" "$help_root/bin"
cp "$repo_root/install.sh" "$help_root/install.sh"
for route in bootstrap-macos install-main; do
  cat >"$help_root/scripts/$route.sh" <<EOF_FIXTURE
#!/bin/bash
printf '%s' '$route' >"\$HELP_CAPTURE"
for argument in "\$@"; do printf ' %s' "\$argument" >>"\$HELP_CAPTURE"; done
EOF_FIXTURE
done
cat >"$help_root/bin/uname" <<'EOF_FIXTURE'
#!/bin/sh
printf '%s\n' "$FAKE_KERNEL"
EOF_FIXTURE
chmod +x "$help_root/install.sh" "$help_root/scripts/"*.sh "$help_root/bin/uname"

assert_help_route() {
  local kernel="$1"
  local expected="$2"
  shift 2
  PATH="$help_root/bin:$PATH" FAKE_KERNEL="$kernel" HELP_CAPTURE="$help_capture" \
    /bin/bash "$help_root/install.sh" "$@"
  [[ "$(<"$help_capture")" == "$expected" ]] || {
    printf 'Expected ./install.sh %s on %s to route to %q, got %q.\n' \
      "$*" "$kernel" "$expected" "$(<"$help_capture")" >&2
    exit 1
  }
}

assert_help_route Darwin 'bootstrap-macos --platform macos --help' --help
assert_help_route Darwin 'bootstrap-macos --platform macos -h' -h
assert_help_route Darwin 'bootstrap-macos --platform macos --rerun --help' --rerun --help
assert_help_route Darwin 'bootstrap-macos --platform macos --help' --platform macos --help
assert_help_route Darwin 'install-main --platform fedora --help' --platform fedora --help
assert_help_route Darwin 'install-main --platform=fedora -h' --platform=fedora -h
assert_help_route Darwin 'install-main --theme mocha' --theme mocha
assert_help_route Linux 'install-main --help' --help
printf 'Help without a platform routes to the macOS bootstrap only on a Mac.\n'

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

# A plan action runs with errexit suppressed (common/lib/execution-plan.sh), and
# this is the one action that runs a statement after its fallible command. A
# failing installer must therefore still be a failing action, or the plan prints
# "[system] completed" for a Mac that never got its Homebrew baseline and every
# later mutating step runs anyway.
failing_root="$test_root/failing-root"
mkdir -p "$failing_root/platforms/macos/scripts"
cat >"$failing_root/platforms/macos/scripts/install-system.sh" <<'EOF_FIXTURE'
#!/usr/bin/env bash
exit 17
EOF_FIXTURE
chmod +x "$failing_root/platforms/macos/scripts/install-system.sh"

homebrew_path_activated=false
activate_homebrew_path() { homebrew_path_activated=true; }
for interactive_argument in true false; do
  status=0
  DOTFILES_ROOT="$failing_root" \
    macos_run_system_installer "$interactive_argument" || status=$?
  if ((status != 17)); then
    printf 'macos_run_system_installer swallowed a failing installer (interactive=%s, status=%s).\n' \
      "$interactive_argument" "$status" >&2
    exit 1
  fi
done
if [[ "$homebrew_path_activated" != false ]]; then
  printf 'macos_run_system_installer activated the Homebrew PATH after the installer failed.\n' >&2
  exit 1
fi
activate_homebrew_path() { :; }
printf 'macOS system-installer failure propagation passed.\n'

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

  # The report: plain help under Apple's Bash 3.2, naming no platform. With a
  # supported Bash it is the real installer's macOS help.
  for help_flag in --help -h; do
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOMEBREW_BIN=/opt/homebrew/bin/brew \
      /bin/bash "$repo_root/install.sh" "$help_flag" >"$test_root/plain-help"
    grep -Fq "Options (platform 'macos'):" "$test_root/plain-help"
  done

  # Without one it is the bootstrap's macOS help, and nothing that could
  # install Homebrew or Bash runs.
  help_guard="$test_root/help-guard"
  mkdir -p "$help_guard"
  cat >"$help_guard/mutation-guard" <<EOF_FIXTURE
#!/bin/sh
printf '%s\n' "\${0##*/}" >>"$test_root/help-mutations"
exit 97
EOF_FIXTURE
  chmod +x "$help_guard/mutation-guard"
  for command_name in curl sudo brew installer; do
    ln -s mutation-guard "$help_guard/$command_name"
  done
  for help_flag in --help -h; do
    PATH="$help_guard:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOMEBREW_BIN="$test_root/missing-brew" \
      /bin/bash "$repo_root/install.sh" "$help_flag" >"$test_root/bootstrap-help"
    grep -Fq 'Usage: ./install.sh --platform macos [options]' "$test_root/bootstrap-help"
    grep -Fq -- '--help never changes the machine' "$test_root/bootstrap-help"
  done
  if [[ -e "$test_root/help-mutations" ]]; then
    printf 'Help ran a mutating command:\n%s\n' "$(<"$test_root/help-mutations")" >&2
    exit 1
  fi

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
