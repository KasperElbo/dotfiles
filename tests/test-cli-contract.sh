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
for rejected in n N no NO ''; do
  if printf '%s\n' "$rejected" | confirm Continue y; then
    printf 'Negative confirmation was accepted: %q\n' "$rejected" >&2; exit 1
  fi
done
if printf 'perhaps\n' | confirm Continue y 2>"$test_root/invalid"; then
  printf 'Invalid confirmation was accepted.\n' >&2; exit 1
fi
grep -Fq 'expected yes or no' "$test_root/invalid"

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
