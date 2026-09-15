#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

space_form="$("$repo_root/install.sh" --platform fedora-wsl --dry-run)"
equals_form="$("$repo_root/install.sh" --platform=fedora-wsl --dry-run)"
[[ "$space_form" == "$equals_form" ]]
if "$repo_root/install.sh" --platform= --dry-run >"$test_root/empty" 2>&1; then
  printf 'Empty --platform= value unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq -- '--platform requires a value' "$test_root/empty"

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
for accepted in y Y yes YES; do printf '%s\n' "$accepted" | confirm Continue n; done
for rejected in n N no NO; do
  if printf '%s\n' "$rejected" | confirm Continue y; then
    printf 'Negative confirmation was accepted: %q\n' "$rejected" >&2; exit 1
  fi
done
if printf 'perhaps\n' | confirm Continue y 2>"$test_root/invalid"; then
  printf 'Invalid confirmation was accepted.\n' >&2; exit 1
fi
grep -Fq 'expected yes or no' "$test_root/invalid"

# An empty answer is the declared default, and the rendered hint says which
# one it is (#225, DOC-035): every caller that asks for "default yes" used to
# be cancelled by pressing Enter.
printf '\n' | confirm Continue y ||
  { printf 'An empty answer did not take the "y" default.\n' >&2; exit 1; }
if printf '\n' | confirm Continue n; then
  printf 'An empty answer did not take the "n" default.\n' >&2; exit 1
fi
if printf '\n' | confirm Continue; then
  printf 'An empty answer did not take the implicit "n" default.\n' >&2; exit 1
fi
default_yes_prompt="$(printf 'n\n' | confirm 'Continue' y 2>&1 || true)"
assert_contains "$default_yes_prompt" '[Y/n]'
default_no_prompt="$(printf 'y\n' | confirm 'Continue' n 2>&1 || true)"
assert_contains "$default_no_prompt" '[y/N]'

# A closed standard input is not an answer: the default must not be inherited
# by a run nobody is watching.
closed_stdin="$(confirm 'Continue' y <&- 2>&1 || true)"
assert_contains "$closed_stdin" 'No answer is available on standard input'
if confirm 'Continue' y <&- >/dev/null 2>&1; then
  printf 'A closed standard input was accepted as a yes.\n' >&2; exit 1
fi

repeated="$("$repo_root/install.sh" --latex --no-latex --dry-run)"
[[ "$repeated" != *'Install LaTeX'* ]]
if "$repo_root/install.sh" '--option containing spaces' >"$test_root/spaces" 2>&1; then
  printf 'Unknown spaced argument unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'Unknown option: --option containing spaces' "$test_root/spaces"

cancelled="$(printf 'no\n' | "$repo_root/install.sh" --no-latex 2>&1)"
[[ "$cancelled" == *'Cancelled; no changes made.'* ]]
[[ "$cancelled" != *'Install LaTeX toolchain?'* ]]

mock_bin="$test_root/bin"; mkdir -p "$mock_bin"
test_stub_init "$test_root"
test_stub_install "$test_root" dnf
test_stub_install "$test_root" sudo
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -u ]] && printf '0\n' || /usr/bin/id "$@"
EOF
chmod +x "$mock_bin"/*
if PATH="$mock_bin:$PATH" "$repo_root/install.sh" --no-kde --no-latex --non-interactive >"$test_root/root" 2>&1; then
  printf 'Root installer invocation unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'Refusing to run the user installer as root' "$test_root/root"
assert_file_empty "$test_root/logs/dnf.log"
assert_file_empty "$test_root/logs/sudo.log"
printf 'CLI selector, confirmation, cancellation, and root policy passed.\n'
