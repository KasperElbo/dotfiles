#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail_with_context() {
  local message="$1"
  local file="${2:-}"
  printf '%s\n' "$message" >&2
  if [[ -n "$file" ]]; then
    printf -- '--- %s ---\n' "$file" >&2
    cat "$file" >&2 2>/dev/null || printf '(missing or unreadable)\n' >&2
  fi
  exit 1
}

# =============================================================================
# render_ini_section_keys: pure-function coverage
# =============================================================================

run_render() {
  # Runs render_ini_section_keys in a fresh subshell so each case starts
  # from a clean sourcing of the library, then prints its result.
  local content="$1"
  shift
  bash -c '
    source "'"$repo_root"'/common/lib/common.sh"
    source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
    render_ini_section_keys "$1" "$2" "${@:3}"
  ' _ "$content" interop "$@"
}

result="$(run_render "" "enabled=true" "appendWindowsPath=false")"
expected=$'[interop]\nenabled=true\nappendWindowsPath=false'
[[ "$result" == "$expected" ]] ||
  fail_with_context "empty content: expected a fresh [interop] section, got:
$result"
printf 'PASS: empty content produces a fresh [interop] section\n'

result="$(run_render $'[boot]\nsystemd=true' "enabled=true" "appendWindowsPath=false")"
expected=$'[boot]\nsystemd=true\n\n[interop]\nenabled=true\nappendWindowsPath=false'
[[ "$result" == "$expected" ]] ||
  fail_with_context "existing [boot] only: unrelated section not preserved correctly, got:
$result"
printf 'PASS: an existing [boot] section is preserved when [interop] is appended\n'

result="$(run_render $'[interop]\nenabled=false\nappendWindowsPath=true\n\n[boot]\nsystemd=true' \
  "enabled=true" "appendWindowsPath=false")"
expected=$'[interop]\nenabled=true\nappendWindowsPath=false\n\n[boot]\nsystemd=true'
[[ "$result" == "$expected" ]] ||
  fail_with_context "wrong existing values: expected in-place correction, got:
$result"
printf 'PASS: wrong existing [interop] values are corrected in place, later sections preserved\n'

result="$(run_render $'[interop]\nhostname=my-machine' "enabled=true" "appendWindowsPath=false")"
expected=$'[interop]\nhostname=my-machine\nenabled=true\nappendWindowsPath=false'
[[ "$result" == "$expected" ]] ||
  fail_with_context "unrelated key in [interop]: not preserved, got:
$result"
printf 'PASS: an unrelated key already in [interop] is preserved alongside the new ones\n'

result="$(run_render $'# a comment\n[interop]\n  enabled = false\nappendWindowsPath=true\n\n[wsl2]\nmemory=4GB' \
  "enabled=true" "appendWindowsPath=false")"
expected=$'# a comment\n[interop]\nenabled=true\nappendWindowsPath=false\n\n[wsl2]\nmemory=4GB'
[[ "$result" == "$expected" ]] ||
  fail_with_context "comments/spacing/trailing section: not preserved, got:
$result"
printf 'PASS: leading comments, spaced keys, and a trailing unrelated section survive unchanged\n'

first="$(run_render $'[boot]\nsystemd=true' "enabled=true" "appendWindowsPath=false")"
second="$(run_render "$first" "enabled=true" "appendWindowsPath=false")"
[[ "$first" == "$second" ]] ||
  fail_with_context "render_ini_section_keys is not idempotent:
first:
$first
second:
$second"
printf 'PASS: render_ini_section_keys is idempotent\n'

# =============================================================================
# configure-interop.sh: script-level coverage
# =============================================================================

new_test_root() {
  local test_root
  test_root="$(mktemp -d)"

  local mock_bin="$test_root/bin"
  mkdir -p "$mock_bin"
  : >"$test_root/commands.log"

  cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
"$@"
EOF
  chmod +x "$mock_bin"/*
  printf 'ID=fedora\n' >"$test_root/os-release"

  printf '%s\n' "$test_root"
}

base_environment() {
  local test_root="$1"

  printf '%s\n' \
    "PATH=$test_root/bin:$PATH" \
    "COMMAND_LOG=$test_root/commands.log" \
    "OS_RELEASE_FILE=$test_root/os-release" \
    "WSL_CONF_FILE=$test_root/wsl.conf" \
    "WSL_DISTRO_NAME=FedoraLinux"
}

# --- dry-run never touches the file or invokes sudo ------------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf '[boot]\nsystemd=true\n' >"$test_root/wsl.conf"

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" --dry-run)"
grep -Fq 'enabled=true' <<<"$dry_run_output"
grep -Fq 'appendWindowsPath=false' <<<"$dry_run_output"
grep -Fq 'wsl --shutdown' <<<"$dry_run_output"
grep -Fq 'No changes were made.' <<<"$dry_run_output"

if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Dry-run invoked sudo' "$test_root/commands.log"
fi
[[ "$(cat "$test_root/wsl.conf")" == $'[boot]\nsystemd=true' ]] ||
  fail_with_context 'Dry-run modified the file on disk'
printf 'PASS: --dry-run reports the plan without touching the file or invoking sudo\n'
rm -rf -- "$test_root"

# --- dry-run on an already-correct file says so and still makes no changes -

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf '[interop]\nenabled=true\nappendWindowsPath=false\n' >"$test_root/wsl.conf"
before="$(sha256sum "$test_root/wsl.conf")"

dry_run_output="$(env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" --dry-run)"
grep -Fq 'no changes needed' <<<"$dry_run_output"

[[ "$(sha256sum "$test_root/wsl.conf")" == "$before" ]] ||
  fail_with_context 'Dry-run modified an already-correct file'
if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Dry-run on an already-correct file invoked sudo' \
    "$test_root/commands.log"
fi
printf 'PASS: --dry-run on an already-correct file reports no changes needed\n'
rm -rf -- "$test_root"

# --- a missing /etc/wsl.conf is created with just [interop] ----------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if ! env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" \
  >"$test_root/run.log" 2>&1; then
  cat "$test_root/run.log" >&2
  fail_with_context 'configure-interop.sh failed against a missing wsl.conf'
fi

[[ -f "$test_root/wsl.conf" ]] ||
  fail_with_context "wsl.conf was not created: $test_root/wsl.conf"
[[ "$(cat "$test_root/wsl.conf")" == $'[interop]\nenabled=true\nappendWindowsPath=false' ]] ||
  fail_with_context "Unexpected wsl.conf content" "$test_root/wsl.conf"
grep -Fq 'wsl --shutdown' "$test_root/run.log"
printf 'PASS: a missing /etc/wsl.conf is created with just [interop]\n'
rm -rf -- "$test_root"

# --- an existing [boot] section and other content survive a real run -------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf '[boot]\nsystemd=true\n\n[wsl2]\nmemory=4GB\n' >"$test_root/wsl.conf"

if ! env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" \
  >"$test_root/run.log" 2>&1; then
  cat "$test_root/run.log" >&2
  fail_with_context 'configure-interop.sh failed with pre-existing unrelated sections'
fi

expected=$'[boot]\nsystemd=true\n\n[wsl2]\nmemory=4GB\n\n[interop]\nenabled=true\nappendWindowsPath=false'
[[ "$(cat "$test_root/wsl.conf")" == "$expected" ]] ||
  fail_with_context "Unrelated sections were not preserved" "$test_root/wsl.conf"
grep -Fq 'sudo install -m 0644' "$test_root/commands.log"
printf 'PASS: a real run preserves unrelated existing sections ([boot], [wsl2])\n'
rm -rf -- "$test_root"

# --- rerunning is a no-op: no sudo call, file untouched ---------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")
printf '[boot]\nsystemd=true\n' >"$test_root/wsl.conf"

env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" >/dev/null
first_content="$(cat "$test_root/wsl.conf")"
: >"$test_root/commands.log"

if ! env "${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" \
  >"$test_root/rerun.log" 2>&1; then
  cat "$test_root/rerun.log" >&2
  fail_with_context 'rerun of configure-interop.sh failed'
fi

[[ "$(cat "$test_root/wsl.conf")" == "$first_content" ]] ||
  fail_with_context 'Rerun changed an already-correct file'
if [[ -s "$test_root/commands.log" ]]; then
  fail_with_context 'Rerun invoked sudo even though the policy was already correct' \
    "$test_root/commands.log"
fi
grep -Fq 'already has the intended' "$test_root/rerun.log"
printf 'PASS: rerunning configure-interop.sh once correct is a true no-op (no sudo, no write)\n'
rm -rf -- "$test_root"

# --- refuses to run off a non-WSL / non-Fedora host -------------------------

test_root="$(new_test_root)"
mapfile -t test_environment < <(base_environment "$test_root")

if env "${test_environment[@]}" WSL_DISTRO_NAME='' \
  KERNEL_RELEASE_FILE="$test_root/not-wsl" \
  "$repo_root/platforms/fedora-wsl/scripts/configure-interop.sh" \
  >"$test_root/not-wsl.log" 2>&1; then
  fail_with_context 'configure-interop.sh accepted a non-WSL host' \
    "$test_root/not-wsl.log"
fi
grep -Fq 'must run inside Windows Subsystem for Linux' "$test_root/not-wsl.log"
printf 'PASS: configure-interop.sh refuses to run outside WSL\n'
rm -rf -- "$test_root"

# =============================================================================
# windows_interop_works / windows_interop_binfmt_hint: pure-function coverage
#
# These back verify.sh's "Windows executable interop" section, distinct
# from the PATH-leakage checks already covered by the Zsh-PATH check and
# check_linux_command in verify.sh itself.
# =============================================================================

new_interop_probe_root() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/System32"
  printf '%s\n' "$root"
}

test_root="$(new_interop_probe_root)"
cat >"$test_root/System32/cmd.exe" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == /c && "$2" == echo && "$3" == interop-ok ]]; then
  printf 'interop-ok\r\n'
  exit 0
fi
exit 1
EOF
chmod +x "$test_root/System32/cmd.exe"

if ! env WINDOWS_SYSTEM_ROOT="$test_root" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  windows_interop_works
'; then
  fail_with_context 'windows_interop_works must succeed against a working cmd.exe mock'
fi
printf 'PASS: windows_interop_works succeeds when the probe executable behaves\n'
rm -rf -- "$test_root"

test_root="$(new_interop_probe_root)"
# No cmd.exe at all -- the "exec format error" / "cannot execute binary
# file" failure mode from issue #104 surfaces the same way as a missing
# executable: the command substitution simply fails.
if env WINDOWS_SYSTEM_ROOT="$test_root" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  windows_interop_works
'; then
  fail_with_context 'windows_interop_works must fail when the probe executable is missing'
fi
printf 'PASS: windows_interop_works fails when the probe executable cannot run\n'
rm -rf -- "$test_root"

test_root="$(new_interop_probe_root)"
mkdir -p "$test_root/binfmt"
: >"$test_root/binfmt/WSLInterop"

hint="$(env BINFMT_MISC_ROOT="$test_root/binfmt" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  windows_interop_binfmt_hint
')"
[[ "$hint" == "WSLInterop" ]] ||
  fail_with_context "windows_interop_binfmt_hint expected 'WSLInterop', got: $hint"

hint="$(env BINFMT_MISC_ROOT="$test_root/no-such-dir" bash -c '
  source "'"$repo_root"'/common/lib/common.sh"
  source "'"$repo_root"'/platforms/fedora-wsl/lib/wsl.sh"
  windows_interop_binfmt_hint
')"
[[ "$hint" == "not found" ]] ||
  fail_with_context "windows_interop_binfmt_hint expected 'not found', got: $hint"
printf 'PASS: windows_interop_binfmt_hint reports what it finds without gating on a name\n'
rm -rf -- "$test_root"

# --- verify.sh gives a useful diagnostic when interop is actually broken ---

test_root="$(mktemp -d)"
mkdir -p "$test_root/System32" "$test_root/bin"
printf 'ID=fedora\n' >"$test_root/os-release"

# require_fedora_wsl and the Zsh-PATH check both need a little more than a
# bare shell: mock the commands they shell out to (Zsh's own -lic startup
# is not available in this sandbox) so the script gets past them and
# actually reaches the "Windows executable interop" section under test,
# without needing this whole repository's much larger install mocks.
cat >"$test_root/bin/dnf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$test_root/bin/dnf" "$test_root/bin/rpm"
cat >"$test_root/bin/zsh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'__DOTFILES_VERIFY_PATH__'* ]]; then
  printf '\n__DOTFILES_VERIFY_PATH__%s\n' "$PATH"
elif [[ "$*" == *'__DOTFILES_VERIFY_STARSHIP__'* ]]; then
  printf '\n__DOTFILES_VERIFY_STARSHIP__%s\n' "not-a-real-config"
fi
EOF
chmod +x "$test_root/bin"/*

verify_output="$(env \
  WSL_DISTRO_NAME=FedoraLinux \
  OS_RELEASE_FILE="$test_root/os-release" \
  WINDOWS_SYSTEM_ROOT="$test_root" \
  BINFMT_MISC_ROOT="$test_root/no-such-binfmt" \
  XDG_CONFIG_HOME="$test_root/xdg" \
  XDG_DATA_HOME="$test_root/xdg/data" \
  HOME="$test_root/home" \
  PATH="$test_root/bin:$PATH" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" 2>&1)" || true

grep -Fq 'explicit Windows executable interop is not working' <<<"$verify_output"
grep -Fq 'enabled=true' <<<"$verify_output"
grep -Fq 'appendWindowsPath=false' <<<"$verify_output"
grep -Fq "wsl --shutdown" <<<"$verify_output"
grep -Fq 'configure-interop.sh' <<<"$verify_output"
printf 'PASS: verify.sh explains what to fix when explicit .exe execution is broken\n'
rm -rf -- "$test_root"

printf '\nFedora WSL /etc/wsl.conf interop policy tests passed.\n'
