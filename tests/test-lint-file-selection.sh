#!/usr/bin/env bash
# What ./scripts/lint.sh decides to check, and that the decision has effect.
#
# The gate used to build its file set from `git ls-files -- '*.sh'`, which
# decides scope by filename extension. A command installed onto PATH does not
# carry one, so fourteen tracked Bash programs were syntax-checked and
# ShellChecked by nothing: bin/.local/bin/theme, doctor, the stowed Sway and
# WSL interop commands, and platforms/fedora/assets/dotfiles-sway, which is the
# Wayland session `Exec=` the display manager runs to start the desktop. A hard
# syntax error could be appended to any of them and lint still printed "Shell
# validation passed".
#
# These are effect tests, not greps over scripts/lint.sh. Each extensionless
# program is broken in a scratch copy of the repository and the real entry point
# is run against it, and the argv ShellCheck is actually handed is recorded from
# a stub rather than inferred from the source.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# The programs the extension rule missed. Naming them here rather than deriving
# them keeps this suite from agreeing with a reader that has stopped working:
# a derived list would shrink with the bug.
extensionless=(
  bin/.local/bin/theme
  doctor
  platforms/fedora-wsl/stow/interop/.local/bin/wsl-copy
  platforms/fedora-wsl/stow/interop/.local/bin/wsl-open
  platforms/fedora-wsl/stow/interop/.local/bin/wsl-paste
  platforms/fedora/assets/dotfiles-sway
  platforms/fedora/stow/sway/.local/bin/power-profile-status
  platforms/fedora/stow/sway/.local/bin/sway-output-cycle
  platforms/fedora/stow/sway/.local/bin/sway-screenshot
  platforms/fedora/stow/sway/.local/bin/sway-session-start
  platforms/fedora/stow/sway/.local/bin/sway-workspace-grid
  platforms/macos/stow/aerospace/.local/bin/aerospace-workspace-grid
  platforms/parrot-ctf/stow/command-shims/.local/bin/bat
  platforms/parrot-ctf/stow/command-shims/.local/bin/fd
)

# scratch_repo <directory>: the tracked tree, copied and committed, so the real
# entry point runs against a real index. Every check here runs `git ls-files`,
# and a directory that is not a repository would fail for the wrong reason.
scratch_repo() {
  local target="$1"
  mkdir -p "$target"
  (cd "$repo_root" && git ls-files -z | tar --null -cf - -T -) | tar xf - -C "$target"
  git -C "$target" init -q
  git -C "$target" -c user.email=test@invalid -c user.name=test add -A
}

# ---------------------------------------------------------------------------
# The reader

listed="$root/listed"
run_capture "$repo_root/scripts/list-shell-files.py" --lines
assert_success
printf '%s\n' "$TEST_OUTPUT" >"$listed"
[[ -s "$listed" ]] ||
  _test_die 'scripts/list-shell-files.py printed nothing, so every check below would prove nothing'

for name in "${extensionless[@]}"; do
  assert_file_line "$listed" "$name"
done
printf 'PASS: the lint file set names all %d tracked programs without a .sh extension\n' \
  "${#extensionless[@]}"

# The floor: the set the glob matched must remain a subset, so a regression in
# the reader cannot silently narrow coverage back past where it started.
glob="$root/glob"
git -C "$repo_root" ls-files -- '*.sh' >"$glob"
[[ -s "$glob" ]] || _test_die 'no tracked *.sh files, so the subset check below proves nothing'
dropped="$(comm -23 <(sort "$glob") <(sort "$listed"))"
[[ -z "$dropped" ]] ||
  _test_die "the reader dropped files the extension glob matched: $dropped"
printf 'PASS: every file the extension glob matched is still in the lint file set\n'

# And the reader refuses to answer at all if that stops being true, rather than
# printing a shorter list. Proved by running it against a tree where a tracked
# .sh file is unreadable as a file the reader will return.
floor_root="$root/floor"
scratch_repo "$floor_root"
python3 - "$floor_root" <<'PYTHON'
import pathlib
import sys

# Break the reader's own rule in the copy: make one tracked .sh file something
# `shell_files` skips, so its floor check has something real to catch.
root = pathlib.Path(sys.argv[1])
target = root / "scripts" / "lib" / "manifests.py"
body = target.read_text(encoding="utf-8")
needle = '        if name.endswith(".sh") or has_shell_shebang(path):\n'
if needle not in body:
    raise SystemExit("manifests.py no longer has the predicate this check mutates")
target.write_text(body.replace(needle, '        if has_shell_shebang(path):\n', 1), encoding="utf-8")
PYTHON
run_capture "$floor_root/scripts/list-shell-files.py" --root "$floor_root" --lines
assert_failure
assert_contains "$TEST_OUTPUT" 'the reader dropped tracked .sh files'
printf 'PASS: the reader fails rather than returning a set narrower than the glob it replaced\n'

# ---------------------------------------------------------------------------
# bash -n reaches those programs

for name in bin/.local/bin/theme doctor platforms/fedora/assets/dotfiles-sway; do
  broken_root="$root/broken-${name//\//-}"
  scratch_repo "$broken_root"
  printf '\nfunction broken( { echo "unbalanced"\n' >>"$broken_root/$name"
  run_capture env -C "$broken_root" ./scripts/lint.sh
  assert_failure
  assert_contains "$TEST_OUTPUT" "$name"
  assert_not_contains "$TEST_OUTPUT" 'Shell validation passed'
  printf 'PASS: a syntax error in %s fails ./scripts/lint.sh\n' "$name"
  rm -rf "$broken_root"
done

# ---------------------------------------------------------------------------
# ShellCheck is handed the same widened set

# lint.sh calls shellcheck once, with every file in its set. Recording that argv
# is the only way to establish what the second consumer actually receives: the
# whole defect was a file set that looked right in one place and was narrower in
# another. The stub exits non-zero so the run stops here rather than going on to
# the validators, which have nothing to say about file selection.
argv_root="$root/argv"
scratch_repo "$argv_root"
stub_bin="$root/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/shellcheck" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$root/shellcheck-argv"
exit 1
STUB
chmod 755 "$stub_bin/shellcheck"
run_capture env -C "$argv_root" "PATH=$stub_bin:$PATH" ./scripts/lint.sh
assert_failure
[[ -s "$root/shellcheck-argv" ]] ||
  _test_die 'lint.sh never reached ShellCheck, so the argv below would prove nothing'
for name in "${extensionless[@]}"; do
  assert_file_line "$root/shellcheck-argv" "$name"
done
printf 'PASS: ./scripts/lint.sh hands ShellCheck all %d extensionless programs\n' \
  "${#extensionless[@]}"

# ---------------------------------------------------------------------------
# The session command's mode is governed

# dotfiles-sway is installed to /usr/local/bin by install-sway.sh, which sets
# the executable bit; the tracked copy is 644. Before this it matched no role
# pattern and `governed()` did not claim it, so neither its syntax nor its mode
# was anyone's responsibility.
roles_root="$root/roles"
scratch_repo "$roles_root"
grep -v $'\tplatforms/fedora/assets/dotfiles-sway\t' \
  "$repo_root/config/shell-file-roles.tsv" >"$roles_root/config/shell-file-roles.tsv"
run_capture python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$roles_root"
assert_failure
assert_contains "$TEST_OUTPUT" 'platforms/fedora/assets/dotfiles-sway'
printf 'PASS: removing the session command from the role inventory fails validation\n'

printf 'Lint file-selection checks passed.\n'
