#!/usr/bin/env bash
# The one piece of behaviour that defines the Fedora WSL profile, executed.
#
# `platform-env.zsh` strips Windows drive mounts out of PATH so that Windows
# executables do not resolve in the Linux development environment. Until this
# suite existed the only check on it was `grep -Fq '/mnt/[a-zA-Z]/*)'` over the
# file's own source text, and the Fedora WSL suite replaces `zsh` with a Bash
# stub that computes PATH itself, so the tracked file was never interpreted by
# a shell in any test. Inverting the case arm so the sanitizer *keeps* every
# Windows path left `./scripts/lint.sh` at 0 and the whole default suite run
# green, printing "Fedora WSL verification rejects a Windows entry the Zsh
# sanitizer hides" while the sanitizer hid nothing (issue #384, PS-01).
#
# So every check here runs the tracked file under real Zsh with a seeded PATH
# and reads the PATH that comes out. The mutations at the end are the control:
# the same checks are re-run against a copy with the sanitizer inverted and
# against a copy with the loop body removed, and must reject both. A suite that
# cannot be made to fail proves nothing about the file it names.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

# Resolved once, by absolute path, because one case below seeds a PATH that
# contains nothing but Windows mounts: looking the interpreter up through the
# PATH under test would fail to find zsh and report 127 instead of an answer.
zsh_bin="$(command -v zsh)" ||
  _test_die 'zsh is required to execute the Fedora WSL PATH sanitizer; install it and rerun'

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

sanitizer="$repo_root/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform-env.zsh"
[[ -f "$sanitizer" ]] || _test_die "the Fedora WSL PATH sanitizer is missing: $sanitizer"

# sanitize <file> <path>: the PATH a login gets after <file> has run, given
# <path> going in. `zsh -f` skips every startup file, so the only thing shaping
# the answer is the file under test. stderr is kept separate: the all-Windows
# case below asserts on both.
sanitize() {
  local file="$1" seeded="$2" quoted
  printf -v quoted '%q' "$file"
  PATH="$seeded" "$zsh_bin" -f -c "source $quoted; printf '%s' \"\$PATH\"" \
    2>"$root/stderr"
}

# ---------------------------------------------------------------------------
# A mixed PATH keeps its Linux entries and loses its Windows ones

mixed_in='/mnt/c/Windows/System32:/usr/bin:/mnt/d/tools:/bin'
mixed_out="$(sanitize "$sanitizer" "$mixed_in")"

[[ "$mixed_out" == '/usr/bin:/bin' ]] ||
  _test_die "expected '/usr/bin:/bin' out of '$mixed_in', got '$mixed_out'"
printf 'PASS: the sanitizer drops Windows drive mounts and keeps Linux entries in order\n'

# Stated separately from the equality above, because this is the property the
# profile exists for and it should fail by name when it breaks.
[[ "$mixed_out" != *'/mnt/'* ]] ||
  _test_die "a Windows mount survived the sanitizer: $mixed_out"
printf 'PASS: no /mnt entry survives a mixed PATH\n'

# ---------------------------------------------------------------------------
# Only Windows *drive* mounts go

# `/mnt/[a-zA-Z]/*` is a drive letter with something under it. An ordinary
# Linux directory that merely lives below /mnt is not a Windows mount, and a
# sanitizer that took the whole of /mnt would silently remove a user's own
# mounted disks from PATH.
kept_in='/mnt/data/bin:/mnt/backup/bin:/opt/mnt/c/bin:/usr/bin'
kept_out="$(sanitize "$sanitizer" "$kept_in")"
[[ "$kept_out" == "$kept_in" ]] ||
  _test_die "the sanitizer removed a Linux directory under /mnt: '$kept_in' became '$kept_out'"
printf 'PASS: a Linux mount point under /mnt survives; only drive-letter mounts go\n'

# ---------------------------------------------------------------------------
# A PATH of nothing but Windows mounts does not become an empty PATH

# The recoverable failure is an unsanitized PATH with a reason on stderr. The
# unrecoverable one is a login shell in which no command resolves at all and
# nothing says why, which is what assigning the empty array produced.
only_windows_in='/mnt/c/Windows/System32:/mnt/d/tools'
only_windows_out="$(sanitize "$sanitizer" "$only_windows_in")"
[[ -n "$only_windows_out" ]] ||
  _test_die 'a PATH of only Windows mounts left PATH empty, so the login shell would have no commands'
assert_file_contains "$root/stderr" 'every PATH entry is a Windows mount'
printf 'PASS: an all-Windows PATH is left alone and said so, rather than emptied\n'

# ---------------------------------------------------------------------------
# The checks above can fail

# Two mutations, each the smallest change that breaks the file in a way the
# original grep could not see. Inverting the arm is the one that was actually
# run against the whole gate stack and passed.
mutate() {
  local label="$1" old="$2" replacement="$3"
  local copy="$root/$label.zsh"
  local body
  body="$(<"$sanitizer")"
  [[ "$body" == *"$old"* ]] ||
    _test_die "the sanitizer no longer contains the text this control replaces: $old"
  printf '%s' "${body/"$old"/"$replacement"}" >"$copy"
  printf '%s' "$copy"
}

inverted="$(mutate inverted \
  '  /mnt/[a-zA-Z]/*) ;;' \
  '  /mnt/[a-zA-Z]/*) _dotfiles_linux_path+=("$_dotfiles_path_entry") ;;')"
inverted_out="$(sanitize "$inverted" "$mixed_in")"
[[ "$inverted_out" == *'/mnt/c/Windows/System32'* ]] ||
  _test_die "the inverted control did not keep the Windows entry, so the checks above prove nothing: $inverted_out"
printf 'PASS: a sanitizer that keeps Windows entries is observably different here\n'

removed="$(mutate removed \
  '  case "$_dotfiles_path_entry" in
  /mnt/[a-zA-Z]/*) ;;
  *) _dotfiles_linux_path+=("$_dotfiles_path_entry") ;;
  esac' \
  '  _dotfiles_linux_path+=("$_dotfiles_path_entry")')"
removed_out="$(sanitize "$removed" "$mixed_in")"
[[ "$removed_out" == "$mixed_in" ]] ||
  _test_die "the no-op control did not leave PATH unchanged, so this suite is not reading the file it thinks: $removed_out"
printf 'PASS: a sanitizer with no case statement leaves PATH untouched, and is observably different here\n'

printf 'Fedora WSL PATH sanitizer checks passed.\n'
