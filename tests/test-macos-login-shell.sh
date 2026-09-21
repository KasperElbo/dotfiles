#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# A registry that deliberately contains two valid Zsh shells, so "any
# registered Zsh" can be distinguished from "Apple's /bin/zsh".
printf '/bin/sh\n/bin/bash\n/bin/zsh\n/opt/homebrew/bin/zsh\n' >"$root/shells"
shell_state="$root/login-shell"

test_stub_init "$root"
test_stub_install "$root" dscl
test_stub_install "$root" sudo
test_stub_allow "$root" dscl . -read /Users/tester UserShell
test_stub_allow "$root" sudo chsh -s /bin/zsh tester

# Directory Services is the source of truth on macOS, and chsh through sudo is
# the only thing allowed to move it.
cat >"$root/handlers/dscl" <<'EOF'
#!/usr/bin/env bash
[[ -s "$SHELL_STATE" ]] || exit 1
printf 'UserShell: %s\n' "$(<"$SHELL_STATE")"
EOF
cat >"$root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
# sudo chsh -s <shell> <user>
printf '%s\n' "$3" >"$SHELL_STATE"
EOF
cat >"$root/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
-u) printf '%s\n' "${MOCK_UID:-1000}" ;;
-un) printf 'tester\n' ;;
*) exit 1 ;;
esac
EOF
chmod +x "$root/handlers/dscl" "$root/handlers/sudo" "$root/bin/id"

run_ensure() {
  local uid="$1"
  local start_shell="$2"

  printf '%s' "$start_shell" >"$shell_state"
  [[ -n "$start_shell" ]] || : >"$shell_state"
  : >"$root/logs/sudo.log"

  # shellcheck disable=SC2016 # The payload expands in the child bash, not here.
  run_capture env \
    PATH="$root/bin:$PATH" \
    TEST_STUB_ROOT="$root" \
    SHELLS_FILE="$root/shells" \
    SHELL_STATE="$shell_state" \
    MOCK_UID="$uid" \
    bash -c '
      # shellcheck disable=SC1090
      source "$1/common/lib/common.sh"
      # shellcheck disable=SC1090
      source "$1/platforms/macos/lib/macos.sh"
      ensure_macos_zsh_login_shell
      printf "changed=%s\n" "${ZSH_LOGIN_SHELL_CHANGED:-unset}"
    ' _ "$repo_root"
}

assert_no_shell_mutation() {
  assert_file_empty "$root/logs/sudo.log"
}

printf 'A compliant Apple Zsh is preserved\n'
run_ensure 1000 /bin/zsh
assert_status 0
assert_contains "$TEST_OUTPUT" 'changed=false'
assert_contains "$TEST_OUTPUT" 'already the default login shell'
assert_no_shell_mutation
assert_eq '/bin/zsh' "$(<"$shell_state")" 'compliant Apple Zsh must not be rewritten'

printf 'A deliberately selected Homebrew Zsh is preserved\n'
run_ensure 1000 /opt/homebrew/bin/zsh
assert_status 0
assert_contains "$TEST_OUTPUT" 'changed=false'
assert_no_shell_mutation
assert_eq '/opt/homebrew/bin/zsh' "$(<"$shell_state")" \
  'a registered Homebrew Zsh must not be replaced with Apple s /bin/zsh'

printf 'Bash is replaced with a registered Zsh and verified\n'
run_ensure 1000 /bin/bash
assert_status 0
assert_contains "$TEST_OUTPUT" 'changed=true'
assert_contains "$TEST_OUTPUT" 'Setting Zsh as the default login shell'
test_stub_assert_called "$root" sudo chsh -s /bin/zsh tester
assert_eq '/bin/zsh' "$(<"$shell_state")" 'the login shell must actually move'

printf 'An unregistered Zsh is not accepted as compliant\n'
run_ensure 1000 /usr/local/bin/zsh
assert_status 0
assert_contains "$TEST_OUTPUT" 'changed=true'
assert_eq '/bin/zsh' "$(<"$shell_state")" \
  'a Zsh missing from the registry must be replaced by a registered one'

printf 'An unknown shell state fails instead of guessing\n'
run_ensure 1000 ''
assert_failure
assert_contains "$TEST_OUTPUT" 'Could not determine the login shell'
assert_no_shell_mutation

printf 'Root invocation refuses to touch the login shell\n'
run_ensure 0 /bin/bash
assert_failure
assert_contains "$TEST_OUTPUT" "Refusing to change root's login shell"
assert_no_shell_mutation
assert_eq '/bin/bash' "$(<"$shell_state")" 'root invocation must not mutate state'

# The preflight has to know whether "sudo chsh" is coming before the plan
# starts (#225, DOC-034). A --non-interactive run that only checked for a
# missing Homebrew blocked on a password prompt inside the system step.
run_change_required() {
  local start_shell="$1"

  printf '%s' "$start_shell" >"$shell_state"
  [[ -n "$start_shell" ]] || : >"$shell_state"
  : >"$root/logs/sudo.log"

  # shellcheck disable=SC2016 # The payload expands in the child bash, not here.
  run_capture env \
    PATH="$root/bin:$PATH" \
    TEST_STUB_ROOT="$root" \
    SHELLS_FILE="$root/shells" \
    SHELL_STATE="$shell_state" \
    MOCK_UID=1000 \
    bash -c '
      # shellcheck disable=SC1090
      source "$1/common/lib/common.sh"
      # shellcheck disable=SC1090
      source "$1/platforms/macos/lib/macos.sh"
      if macos_login_shell_change_required; then
        printf "required=true\n"
      else
        printf "required=false\n"
      fi
    ' _ "$repo_root"
}

printf 'A compliant login shell needs no privileged change
'
for compliant in /bin/zsh /opt/homebrew/bin/zsh; do
  run_change_required "$compliant"
  assert_status 0
  assert_contains "$TEST_OUTPUT" 'required=false'
done
assert_no_shell_mutation

printf 'A non-Zsh, unregistered Zsh or unreadable shell needs one
'
for pending in /bin/bash /usr/local/bin/zsh ''; do
  run_change_required "$pending"
  assert_status 0
  assert_contains "$TEST_OUTPUT" 'required=true'
done
assert_no_shell_mutation

printf "The macOS preflight establishes sudo for that change\n"
grep -Fq 'macos_login_shell_change_required || needs_sudo=true' \
  "$repo_root/platforms/macos/install.sh" ||
  {
    printf 'The macOS preflight no longer consults the login-shell requirement.\n' >&2
    exit 1
  }

printf 'macOS login-shell policy tests passed.\n'
