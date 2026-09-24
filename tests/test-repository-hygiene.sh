#!/usr/bin/env bash
# Repository hygiene regressions (#162): orphan npm lockfiles, unreferenced
# upstream licence texts, and a licensing page that disagrees with the tree.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

validator="$repo_root/scripts/validate-repository-hygiene.py"

# new_clean_tree: a minimal tree that satisfies every rule, so each negative
# case below can introduce exactly one defect.
new_clean_tree() {
  test_new_root
  tree="$TEST_ROOT/tree"
  mkdir -p "$tree/docs/reference" "$tree/LICENSES" "$tree/vendor" \
    "$tree/scripts" "$tree/.github/workflows"
  printf 'MIT License\n' >"$tree/LICENSES/Upstream.txt"
  printf 'vendored\n' >"$tree/vendor/thing.conf"
  # The gates validate.yml has to run: a tree without one of them, or with a
  # workflow that does not run it for real, is a defect of its own, so the
  # clean fixture carries each command and a workflow that runs all four.
  mkdir -p "$tree/tests"
  local gate
  for gate in scripts/scan-secrets.sh scripts/lint.sh scripts/test.sh \
    tests/test-windows-static-analysis.ps1; do
    printf '#!/usr/bin/env bash\n' >"$tree/$gate"
  done
  cat >"$tree/.github/workflows/validate.yml" <<'EOF'
name: Validate
on:
  pull_request:
  push:
    branches:
      - main
concurrency:
  group: validate-${{ github.workflow }}-${{ github.event_name == 'push' && github.sha || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  repository:
    runs-on: ubuntu-latest
    name: Repository validation
    steps:
      - name: Scan for committed credentials
        run: ./scripts/scan-secrets.sh
      - name: Validate shell scripts
        run: ./scripts/lint.sh
      - name: Test bootstrap and installer behavior
        run: ./scripts/test.sh
  cheatsheets:
    runs-on: ubuntu-latest
    name: Printable cheat sheets
    steps:
      - run: "true"
  windows:
    runs-on: windows-latest
    name: Windows PowerShell validation
    steps:
      - name: Analyse every tracked PowerShell file
        shell: pwsh
        run: ./tests/test-windows-static-analysis.ps1
  macos:
    runs-on: macos-26
    name: macOS 26 arm64 validation
    steps:
      - run: "true"
EOF
  # Where the required jobs are named for a reader, which has to agree with
  # the workflow; the real page is copied in by new_real_workflow_tree.
  cat >"$tree/docs/testing.md" <<'EOF'
# Testing

| Job | Runner / image | What it runs |
| --- | --- | --- |
| `repository` (Repository validation) | `ubuntu-latest` | the suite |
| `cheatsheets` (Printable cheat sheets) | `ubuntu-latest` | the sheets |
| `windows` (Windows PowerShell validation) | `windows-latest` | the analysis |
| `macos` (macOS 26 arm64 validation) | `macos-26` | lint |

**Merging should require the four Validate jobs on an up-to-date branch.**
The rule names `Repository validation`, `Printable cheat sheets`,
`Windows PowerShell validation` and `macOS 26 arm64 validation`.
EOF
  cat >"$tree/docs/reference/third-party-notices.md" <<'EOF'
# Third-party notices

| Material | Path | Licence text |
|---|---|---|
| Thing | `vendor/thing.conf` | [`LICENSES/Upstream.txt`](../../LICENSES/Upstream.txt) |
EOF
  cat >"$tree/docs/reference/licensing.md" <<'EOF'
# Licensing

**Status: undecided — this requires a maintainer decision.**
EOF
}

# --- The real repository is clean ------------------------------------------

run_capture python3 "$validator"
assert_success
printf 'PASS: this repository satisfies the hygiene rules\n'

new_clean_tree
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a clean fixture tree satisfies the hygiene rules\n'

# --- A lone root npm lockfile is rejected ----------------------------------

for lockfile in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml; do
  new_clean_tree
  printf '{}\n' >"$tree/$lockfile"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" "$lockfile exists at the repository root"
done
printf 'PASS: a root lockfile without a root package.json is rejected\n'

# --- A lockfile belonging to a real root project is accepted ---------------

new_clean_tree
printf '{}\n' >"$tree/package-lock.json"
printf '{"name":"example"}\n' >"$tree/package.json"
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a lockfile with its manifest is accepted\n'

# --- A nested project lockfile is not a root lockfile ----------------------

new_clean_tree
mkdir -p "$tree/tests/fixtures/app"
printf '{}\n' >"$tree/tests/fixtures/app/package-lock.json"
printf '{"name":"app"}\n' >"$tree/tests/fixtures/app/package.json"
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: fixture projects below the root are untouched by the rule\n'

# --- Retained licence texts must be referenced -----------------------------

new_clean_tree
printf 'BSD License\n' >"$tree/LICENSES/Unreferenced.txt"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "LICENSES/Unreferenced.txt is retained but not referenced"
printf 'PASS: an unreferenced upstream licence text is rejected\n'

# --- Notices must not point at paths that no longer exist ------------------

new_clean_tree
rm -- "$tree/vendor/thing.conf"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "names a repository path that does not exist: vendor/thing.conf"
printf 'PASS: a stale path in the third-party notices is rejected\n'

new_clean_tree
rm -- "$tree/LICENSES/Upstream.txt"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "links to a path that does not exist"
printf 'PASS: a broken licence-text link in the third-party notices is rejected\n'

# --- The licence decision and the tree must agree --------------------------

new_clean_tree
printf 'MIT License\n' >"$tree/LICENSE"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "records the decision as undecided"
printf 'PASS: adding a licence file without recording the decision is rejected\n'

new_clean_tree
printf '# Licensing\n\n**Status: decided — MIT.**\n' >"$tree/docs/reference/licensing.md"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "but no root licence file"
printf 'PASS: recording a decision without adding the licence file is rejected\n'

new_clean_tree
printf '# Licensing\n\n**Status: decided — MIT.**\n' >"$tree/docs/reference/licensing.md"
printf 'MIT License\n' >"$tree/LICENSE"
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a decided licence with its root file is accepted\n'

new_clean_tree
printf '# Licensing\n\nSomeday we will decide.\n' >"$tree/docs/reference/licensing.md"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "must open with either"
printf 'PASS: an unstated licence status is rejected\n'

# --- The repository's own licence decision is recorded and consistent -------

assert_path_exists "$repo_root/LICENSE"
assert_file_contains "$repo_root/LICENSE" 'MIT License'
assert_file_contains "$repo_root/LICENSE" 'Copyright (c)'
assert_file_line "$repo_root/docs/reference/licensing.md" '**Status: decided — MIT.**'
assert_file_contains "$repo_root/README.md" 'MIT'
printf 'PASS: the MIT decision is recorded at the root and on the licensing page\n'

# Removing the licence without retracting the decision must fail, so the two
# cannot drift apart later.
new_clean_tree
printf '# Licensing\n\n**Status: decided — MIT.**\n' >"$tree/docs/reference/licensing.md"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "but no root licence file"
printf 'PASS: deleting LICENSE while the page still claims MIT is rejected\n'

# --- A tracked Python bytecode artifact is rejected -------------------------
#
# The bytecode filename below is assembled from parts rather than written as
# one literal path: a contiguous "tests/.../*.py[c]" string in *this* file
# would itself be caught by validate-repository-hygiene.py's own
# nonexistent-repository-path check.

pycache_dirname="__pycache__"
bytecode_basename="smoke.cpython-311.py"
bytecode_basename+="c"

new_clean_tree
git -C "$tree" init --quiet
mkdir -p "$tree/tests/support/$pycache_dirname"
printf 'bytecode\n' >"$tree/tests/support/$pycache_dirname/$bytecode_basename"
git -C "$tree" add --all
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "is a regenerated Python bytecode artifact tracked in git"
printf 'PASS: a tracked __pycache__/*.pyc file is rejected\n'

# An untracked .pyc file (the ordinary case once .gitignore covers it) must
# not be flagged.
new_clean_tree
mkdir -p "$tree/tests/support/$pycache_dirname"
printf 'bytecode\n' >"$tree/tests/support/$pycache_dirname/$bytecode_basename"
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: an untracked __pycache__ directory is not flagged\n'

# --- Messages must cite the document that owns the subject ------------------
#
# These two rules read the git index, so their fixture has to be a repository
# of its own rather than the plain directory the rules above use.

new_tracked_tree() {
  new_clean_tree
  tracked="$tree"
  mkdir -p "$tracked/docs/profiles" "$tracked/scripts"
  printf '# AI toolchain\n' >"$tracked/docs/profiles/ai.md"
  git -C "$tracked" init -q
}

write_script() {
  cat >"$tracked/scripts/install-thing.sh"
  git -C "$tracked" add -A
}

new_tracked_tree
write_script <<'EOF'
#!/usr/bin/env bash
printf 'see docs/profiles/ai.md for the manual steps\n'
EOF
run_capture python3 "$validator" --root "$tracked"
assert_success
printf 'PASS: a script citing a documentation page that exists is accepted\n'

new_tracked_tree
rm -- "$tracked/docs/profiles/ai.md"
write_script <<'EOF'
#!/usr/bin/env bash
printf 'see docs/profiles/ai.md for the manual steps\n'
EOF
run_capture python3 "$validator" --root "$tracked"
assert_failure
assert_contains "$TEST_OUTPUT" 'names a repository path that does not exist: docs/profiles/ai.md'
printf 'PASS: a script naming a documentation page that does not exist is rejected\n'

# Prose about an upstream project routinely names that project's own docs, so
# the documentation rule deliberately stops at scripts. Every fixture citation
# below is assembled at run time: spelled out here, it would be a violation in
# this file, which the rules also govern.
new_tracked_tree
# shellcheck disable=SC2016 # Backticks are Markdown, not command substitution.
printf 'Reads its own `docs/%s.md` for required tools.\n' configuration \
  >"$tracked/docs/profiles/upstream.md"
git -C "$tracked" add -A
run_capture python3 "$validator" --root "$tracked"
assert_success
printf "PASS: prose naming an upstream project's own docs is left alone\n"

readme='README.md'
for separator in ',' "'s"; do
  new_tracked_tree
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo %ssee %s%s "Optional: GNHF" first%s\n' "'" "$readme" "$separator" "'"
  } | write_script
  run_capture python3 "$validator" --root "$tracked"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'cites a README section by name'
done
printf 'PASS: a message citing a README section by name is rejected\n'

# A plain mention of the README, with no section name, is not the defect.
new_tracked_tree
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo %sthe index is %s%s\n' "'" "$readme" "'"
} | write_script
run_capture python3 "$validator" --root "$tracked"
assert_success
printf 'PASS: naming the README without quoting a section is accepted\n'

# --- The shared libraries source common.sh themselves (#268) ----------------

# The convention is enforced by scripts/validate-library-guards.py rather than
# by review, so what is asserted here is that the checker actually refuses a
# tree that breaks it. Without this the checker could pass vacuously -- and a
# checker that cannot fail is the defect this repository files issues about.
guard_validator="$repo_root/scripts/validate-library-guards.py"

run_capture python3 "$guard_validator"
assert_success
printf 'PASS: every shared library reaches common.sh\n'

guard_tree="$TEST_ROOT/guard-tree"
mkdir -p "$guard_tree/common"
cp -r "$repo_root/common/lib" "$guard_tree/common/lib"

# Removing one guard must be refused, and the message must name the file and
# the symbols that stop resolving, so the reader knows what broke.
python3 - "$guard_tree/common/lib/fetch.sh" <<'PYTHON'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
guard = re.compile(
    r'if \[\[ -z "\$\{DOTFILES_COMMON_LOADED:-\}" \]\]; then\n'
    r"  # shellcheck source=common\.sh\n"
    r'  source "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/common\.sh"\n'
    r"fi\n\n"
)
if not guard.search(text):
    raise SystemExit("common/lib/fetch.sh no longer carries the guard to remove")
path.write_text(guard.sub("", text, count=1), encoding="utf-8")
PYTHON

run_capture python3 "$guard_validator" --root "$guard_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'common/lib/fetch.sh uses'
assert_contains "$TEST_OUTPUT" 'die'
assert_contains "$TEST_OUTPUT" 'but never sources it'
printf 'PASS: removing a guard is refused, naming the file and the symbols\n'

# A library that reaches common.sh through a guarded sibling is accepted: that
# is how install-lifecycle.sh and theme-selection.sh are already written, and
# demanding a repeated block would be noise rather than safety.
cat >"$guard_tree/common/lib/borrows.sh" <<'EOF_BORROWS'
#!/usr/bin/env bash

# shellcheck source=verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/verify.sh"

borrows_probe() { die "unreachable"; }
EOF_BORROWS
cp "$repo_root/common/lib/fetch.sh" "$guard_tree/common/lib/fetch.sh"
run_capture python3 "$guard_validator" --root "$guard_tree"
assert_success
printf 'PASS: reaching common.sh through a guarded sibling is accepted\n'

# The fixture's own path is composed from a variable, because
# check_repository_references above refuses a tracked file that names a
# repository path which does not exist, and this one deliberately does not.
guard_lib="$guard_tree/common/lib"

# A name in prose is not a call. This checker read each library as one string
# and matched the symbol anywhere in it, so a library whose only mention of
# `die` and `warn` was ordinary English in a comment was told to add a guard
# for functions it never calls. Six libraries in this tree mention a
# common.sh function in a comment and nowhere else, so this was not
# hypothetical; they only passed because they source common.sh for other
# reasons.
cat >"$guard_lib/prose.sh" <<'EOF_PROSE'
#!/usr/bin/env bash

# This library calls nothing from common.sh. The paragraph below is prose:
# callers should die rather than continue when the input is malformed, and
# the installer will warn about it first. Nothing here reads DOTFILES_ROOT
# or XDG_STATE_HOME either.

prose_value() {
  printf 'x\n'
}
EOF_PROSE

# The rest of the tree is clean at this point, so the whole run passing is a
# stronger statement than the absence of one message: nothing about this file
# is demanded at all.
run_capture python3 "$guard_validator" --root "$guard_tree"
assert_success
printf 'PASS: a common.sh name in a comment is not read as a call\n'

# The same words as code, so the demand is still made where it is due. The
# variable half keeps strings, because "$DOTFILES_ROOT/config" is a real read.
cat >"$guard_lib/prose.sh" <<'EOF_CALLS'
#!/usr/bin/env bash

prose_value() {
  [[ -n "${1:-}" ]] || die "prose_value needs an argument"
  printf '%s\n' "$DOTFILES_ROOT/$1"
}
EOF_CALLS

run_capture python3 "$guard_validator" --root "$guard_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'prose.sh uses DOTFILES_ROOT, die'
printf 'PASS: the same names as code are still demanded, strings included\n'

# A guard that has been commented out sources nothing. The block was matched
# in the raw text, so a commented `if` line above an unguarded file could
# satisfy it; reading the file as code removes that shape entirely.
cat >"$guard_lib/prose.sh" <<'EOF_COMMENTED'
#!/usr/bin/env bash

# if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
#   # shellcheck source=common.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# fi

prose_value() {
  die "always"
}
EOF_COMMENTED

run_capture python3 "$guard_validator" --root "$guard_tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'prose.sh uses die'
printf 'PASS: a commented-out guard does not satisfy the rule\n'

rm -f "$guard_lib/prose.sh"
run_capture python3 "$guard_validator" --root "$guard_tree"
assert_success

# --- Workflow actions must be pinned to a commit ---------------------------

# A tag is whatever its owner last pointed it at, so an action pinned to one
# can be replaced under CI without a commit here. The fixture tree writes the
# three shapes the rule distinguishes.
new_workflow_tree() {
  new_clean_tree
  mkdir -p "$tree/.github/workflows"
  cat >"$tree/.github/workflows/example.yml" <<'EOF'
name: Example
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: ./.github/actions/local-thing
      - name: Check whitespace
        run: git diff --check "origin/$BASE_REF...HEAD"
EOF
}

new_workflow_tree
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a pinned action with its tag comment, and a local action, are accepted\n'

new_workflow_tree
sed -i 's|actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1|actions/checkout@v7|' \
  "$tree/.github/workflows/example.yml"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "actions/checkout is pinned to 'v7', which is a mutable reference"
printf 'PASS: an action pinned to a tag is rejected\n'

new_workflow_tree
sed -i 's| # v7.0.1$||' "$tree/.github/workflows/example.yml"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'pinned to a commit with no trailing comment naming the tag'
printf 'PASS: a bare SHA with no tag comment is rejected\n'

# --- A whitespace check must compare a range -------------------------------

new_workflow_tree
sed -i 's|run: git diff --check .*|run: git diff --check|' \
  "$tree/.github/workflows/example.yml"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'names no range between two different commits'
printf 'PASS: a whitespace check with no range is rejected\n'

# The rule is "names a range", not "has an argument". These are the two forms
# someone reaches for on being told the bare form is not enough, and both
# compare something a runner cannot dirty: --cached compares the index to HEAD,
# identical after actions/checkout, and a lone pathspec compares the working
# tree to the index.
#
# A range whose two ends are the same commit has the shape and compares
# nothing, so it is the subtle spelling of the same defect (#506).
for vacuous in '--cached' '--staged' '-- .' 'HEAD' 'HEAD..HEAD' 'HEAD HEAD' \
  '"$BEFORE_SHA...$BEFORE_SHA"' '..'; do
  new_workflow_tree
  sed -i "s|run: git diff --check .*|run: git diff --check $vacuous|" \
    "$tree/.github/workflows/example.yml"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'names no range between two different commits'
done
printf 'PASS: an argument that compares nothing is rejected as no range\n'

# The call is found as shell words, not as `diff --check` written adjacently:
# each of these is the bare, unranged command, and the adjacent-text reading
# accepted every one of them.
for spelling in 'git diff --exit-code --check' 'git --no-pager diff --check' \
  'git -C . diff --stat --check' 'git diff --check "$BEFORE_SHA..HEAD" \&\& git diff --check'; do
  new_workflow_tree
  sed -i "s|run: git diff --check .*|run: $spelling|" \
    "$tree/.github/workflows/example.yml"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'names no range between two different commits'
done
printf 'PASS: the unranged command is caught however its options are ordered\n'

# And the forms that do name a range are accepted, including a range narrowed
# by a pathspec, so the rule does not push anyone back to the bare form.
for ranged in '"$BEFORE_SHA..HEAD"' '"origin/$BASE_REF...HEAD" -- docs/' 'main HEAD'; do
  new_workflow_tree
  sed -i "s|run: git diff --check .*|run: git diff --check $ranged|" \
    "$tree/.github/workflows/example.yml"
  run_capture python3 "$validator" --root "$tree"
  assert_success
done
printf 'PASS: every spelling that names a range is accepted\n'

# The rule exists because the unranged form cannot fail. This is that claim,
# proved against git rather than asserted: one fixture repository, one commit
# that adds trailing whitespace, both spellings of the step run against it.
test_new_root
fixture_repo="$TEST_ROOT/whitespace-fixture"
mkdir -p "$fixture_repo"
git -C "$fixture_repo" init --quiet
git -C "$fixture_repo" config user.email ci@example.invalid
git -C "$fixture_repo" config user.name CI
printf 'clean\n' >"$fixture_repo/file.txt"
git -C "$fixture_repo" add file.txt
git -C "$fixture_repo" commit --quiet -m 'clean baseline'
base_sha="$(git -C "$fixture_repo" rev-parse HEAD)"
printf 'trailing   \n' >>"$fixture_repo/file.txt"
git -C "$fixture_repo" add file.txt
git -C "$fixture_repo" commit --quiet -m 'commit trailing whitespace'

# The step body as validate.yml runs it, read out of the workflow rather than
# retyped: every `Check whitespace` step's `run:` block, dedented.
whitespace_steps() {
  python3 - "$repo_root/.github/workflows/validate.yml" <<'PYTHON'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
bodies = []
for index, line in enumerate(lines):
    if line.strip() != "- name: Check whitespace":
        continue
    indent = len(line) - len(line.lstrip())
    for cursor in range(index + 1, len(lines)):
        following = lines[cursor]
        if following.strip() and len(following) - len(following.lstrip()) <= indent:
            break
        if following.strip() != "run: |":
            continue
        block = []
        body_indent = None
        for step in range(cursor + 1, len(lines)):
            text = lines[step]
            if not text.strip():
                break
            width = len(text) - len(text.lstrip())
            if body_indent is None:
                body_indent = width
            if width < body_indent:
                break
            block.append(text[body_indent:])
        bodies.append("\n".join(block))
        break
if not bodies:
    raise SystemExit("no 'Check whitespace' step with a run block in validate.yml")
print("\0".join(bodies), end="")
PYTHON
}

mapfile -t -d '' steps < <(whitespace_steps)
assert_eq 2 "${#steps[@]}" 'validate.yml must carry two Check whitespace steps'

for step in "${steps[@]}"; do
  step_script="$TEST_ROOT/step.sh"
  printf '%s\n' "$step" >"$step_script"
  run_capture env -C "$fixture_repo" EVENT_NAME=push BEFORE_SHA="$base_sha" \
    BASE_REF=main bash "$step_script"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'trailing whitespace'
done
printf 'PASS: both Check whitespace steps fail on a committed whitespace defect\n'

# And the form the macOS job used to run, on the same commit, does not.
run_capture env -C "$fixture_repo" git diff --check
assert_success
printf 'PASS: the unranged form passes the same commit, which is why it changed\n'

# --- Every check_symlink call site names its Stow source (#369) -------------
#
# The helper takes the expected source as an optional third argument, which is
# what let the migration run one platform at a time and equally what would let
# the weak two-argument form come back unnoticed: it is not a syntax error, and
# its output is a tick like any other. What is asserted here is that the gate
# actually refuses a tree that regresses, because a checker that cannot fail is
# the defect this repository files issues about.
symlink_validator="$repo_root/scripts/validate-symlink-checks.py"

run_capture python3 "$symlink_validator"
assert_success
printf 'PASS: every migrated check_symlink call site names its Stow source\n'

# The fixture is a repository of its own: the file set comes from the git
# index, the same way the lint gate picks it.
# Assembled at run time, as the fixture citations above are: spelled out, a
# path into a tree that exists only inside this suite would be a violation of
# the rule three sections up, which governs this file too.
symlink_fixture_root="$(printf 'platforms/%s/scripts/verify.sh' example)"

new_symlink_tree() {
  new_clean_tree
  symlink_tree="$tree"
  mkdir -p "$symlink_tree/$(dirname "$symlink_fixture_root")"
  git -C "$symlink_tree" init -q
}

write_verifier() {
  cat >"$symlink_tree/$symlink_fixture_root"
  git -C "$symlink_tree" add -A
}

new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" "$DOTFILES_ROOT/zsh/.zshenv"
check_symlink "$HOME/.tmux.conf" \
  "$DOTFILES_ROOT/tmux" \
  "$DOTFILES_ROOT/tmux/.tmux.conf"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_success
printf 'PASS: three-argument call sites are accepted, continuation lines included\n'

# The defect itself: a call site that proves only containment.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_failure
assert_contains "$TEST_OUTPUT" "$symlink_fixture_root calls check_symlink without an expected source"
printf 'PASS: a two-argument call site is rejected\n'

# Three arguments are not enough on their own: before #507 (V4-03) the gate
# counted them and never read the third, so each shape below passed lint while
# proving no more than the two-argument form. The empty literal is the obvious
# one; the rest look like a real source at a glance.
symlink_source_case() {
  local call="$1" expected="$2"
  new_symlink_tree
  printf '#!/usr/bin/env bash\n%s\n' "$call" | write_verifier
  run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
  assert_failure
  assert_contains "$TEST_OUTPUT" "$symlink_fixture_root:2 $expected"
}
symlink_source_case 'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" ""' \
  'passes an empty expected source'
symlink_source_case 'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" "$HOME/.zshenv"' \
  'passes the link itself as its expected source'
symlink_source_case 'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" "$DOTFILES_ROOT/git/.zshenv"' \
  'passes an expected source that is not written inside the package it names'
# A sibling package sharing a name prefix is not inside it.
symlink_source_case 'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" "$DOTFILES_ROOT/zsh-extra/.zshenv"' \
  'passes an expected source that is not written inside the package it names'
symlink_source_case 'check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" "$DOTFILES_ROOT/zsh/.zshenv" "extra"' \
  'calls check_symlink with 4 argument(s); it takes two or three'
printf 'PASS: a third argument that names no real source is rejected, not counted\n'

# The package root written with a trailing slash, as the Fedora verifiers
# write it, still contains its own files.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh/" "$DOTFILES_ROOT/zsh/.zshenv"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_success
printf 'PASS: a package root written with a trailing slash contains its files\n'

# A file still being migrated is exempt up to the exact number of call sites
# it started with, and no further: a new weak one fails on the commit that
# adds it rather than being absorbed by the exemption.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh"
check_symlink "$HOME/.tmux.conf" "$DOTFILES_ROOT/tmux"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" \
  --migrating "$symlink_fixture_root=2"
assert_success
printf 'PASS: a file still being migrated is exempt up to its recorded count\n'

run_capture python3 "$symlink_validator" --root "$symlink_tree" \
  --migrating "$symlink_fixture_root=1"
assert_failure
assert_contains "$TEST_OUTPUT" 'up from the 1 this migration started with'
printf 'PASS: a weak call site beyond the recorded count is rejected\n'

# ...and the exemption cannot outlive the migration it describes: once a call
# site is migrated the number has to come down with it.
run_capture python3 "$symlink_validator" --root "$symlink_tree" \
  --migrating "$symlink_fixture_root=3"
assert_failure
assert_contains "$TEST_OUTPUT" 'is down to 2 two-argument check_symlink call(s) from 3'
printf 'PASS: a migrated call site is not left behind in the exemption list\n'

# A shape the gate cannot read is reported rather than skipped. A call whose
# arguments are not all double-quoted would otherwise be counted as zero
# arguments -- silently satisfying a rule about how many it has.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink $link "$DOTFILES_ROOT/zsh" "$DOTFILES_ROOT/zsh/.zshenv"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_failure
assert_contains "$TEST_OUTPUT" 'in a shape this gate cannot read'
printf 'PASS: a call site the gate cannot parse is reported, not skipped\n'

# check_symlink_owned in common/verify-ai.sh is a different function with a
# different contract, and matching the helper's name as a substring swept it
# in. Nothing here is a check_symlink call site at all.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
check_symlink_owned "Claude Code (CLAUDE.md)" "$claude_md_target"
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_failure
assert_contains "$TEST_OUTPUT" 'the check would pass vacuously'
printf 'PASS: check_symlink_owned is not read as a check_symlink call site\n'

# A tree with no call sites at all passes every rule above without proving
# anything, so it is a failure rather than a green run.
new_symlink_tree
write_verifier <<'EOF'
#!/usr/bin/env bash
printf 'nothing to see\n'
EOF
run_capture python3 "$symlink_validator" --root "$symlink_tree" --migrating ''
assert_failure
assert_contains "$TEST_OUTPUT" 'the check would pass vacuously'
printf 'PASS: a tree with no call sites fails instead of passing vacuously\n'

# --- The secret-scanning gate (#377) ---------------------------------------
#
# README.md claims categorically that nothing secret is in this repository.
# Until now nothing checked every tracked path, and nothing checked history at
# all, so that was the one repository-wide promise with no gate behind it.
#
# Two things have to hold and both are tested here: the gate must actually
# catch a credential using the command CI runs, and it must not be removable
# without a refusal.

scanner="$repo_root/scripts/scan-secrets.sh"

# The pinned scanner, resolved the way scripts/scan-secrets.sh resolves it and
# never downloaded here: no suite in this repository reaches the network. In
# CI the "Scan for committed credentials" step runs before ./scripts/test.sh
# in the same job, so the cache below is already populated by the time this
# runs. On a workstation, running the scanner once does the same.
pinned_version="$(sed -n 's/^version="\([^"]*\)"$/\1/p' "$scanner")"
[[ -n "$pinned_version" ]] ||
  _test_die "scripts/scan-secrets.sh no longer states its version once"

gitleaks="${DOTFILES_GITLEAKS:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/gitleaks/$pinned_version/gitleaks}"
[[ -x "$gitleaks" ]] ||
  _test_die "the pinned gitleaks $pinned_version is required to test the secret-scanning gate; run ./scripts/scan-secrets.sh once to cache it, or set DOTFILES_GITLEAKS (looked in $gitleaks)"

# A checkout-shaped fixture: the real scanner and the real configuration, over
# a tree this suite owns. The script resolves its repository root from its own
# location, so copying it under $fixture is what points it at the fixture, and
# the symlinks mean the rules and the shared libraries under test are the
# tracked ones rather than a copy that could drift.
test_new_root
scan_fixture="$TEST_ROOT/scan-fixture"
mkdir -p "$scan_fixture/scripts"
cp "$scanner" "$scan_fixture/scripts/scan-secrets.sh"
ln -s "$repo_root/common" "$scan_fixture/common"
ln -s "$repo_root/.gitleaks.toml" "$scan_fixture/.gitleaks.toml"
git -C "$scan_fixture" init -q .
git -C "$scan_fixture" -c user.email=t@example.invalid -c user.name=Test \
  commit -q --allow-empty -m 'empty'

scan_the_fixture() {
  run_capture env -C "$scan_fixture" DOTFILES_GITLEAKS="$gitleaks" \
    ./scripts/scan-secrets.sh
}

scan_the_fixture
assert_success
printf 'PASS: the secret scanner passes a tree with no credential in it\n'

# The credential is assembled from parts so that this file never contains one:
# a literal here would have to be allowlisted, and an allowlisted literal is a
# match the gate has been told to ignore for good. .gitleaks.toml explains the
# same rule. These are syntactically valid and grant nothing.
printf 'aws_access_key_id = "%s%s"\n' 'AKIA' 'QYLPT5RZ2MJKF3WX' \
  >"$scan_fixture/config.ini"
scan_the_fixture
assert_failure
assert_contains "$TEST_OUTPUT" 'A credential was found'
printf 'PASS: a credential in the working tree fails the exact command CI runs\n'

# Redacted, so a CI log never becomes the second place the credential lives.
assert_not_contains "$TEST_OUTPUT" 'QYLPT5RZ2MJKF3WX'
printf 'PASS: the finding is reported without reprinting the secret\n'

# Committed and deleted is still committed: the working-tree scan alone goes
# clean here, and only the history scan still sees it. This is the case the
# whole "scan history too" decision exists for.
git -C "$scan_fixture" add config.ini
git -C "$scan_fixture" -c user.email=t@example.invalid -c user.name=Test \
  commit -q -m 'add configuration'
# Only that one path, because the scanner, the rules and the shared libraries
# sit in this fixture untracked on purpose: committing them would put them in
# the history the reset below rewinds, and take them away with it.
git -C "$scan_fixture" rm -q config.ini
git -C "$scan_fixture" -c user.email=t@example.invalid -c user.name=Test \
  commit -q -m 'remove configuration'

run_capture env -C "$scan_fixture" "$gitleaks" dir . \
  --config "$scan_fixture/.gitleaks.toml" --no-banner --redact --exit-code 1
assert_success

scan_the_fixture
assert_failure
assert_contains "$TEST_OUTPUT" 'A credential was found'
printf 'PASS: a credential removed from the tree is still caught in history\n'

# A different rule, to prove the gate is not one pattern wide.
git -C "$scan_fixture" reset -q --hard HEAD~2
printf -- '-----BEGIN RSA PRIVATE %s-----\n%s\n-----END RSA PRIVATE %s-----\n' \
  'KEY' 'MIIEpAIBAAKCAQEA4Zx9qT2mVbN7cLrY8wKfDsEoQ1hJiUvXgPnMt6RaBw3ZkSyF' 'KEY' \
  >"$scan_fixture/id_rsa"
scan_the_fixture
assert_failure
rm -f "$scan_fixture/id_rsa"
printf 'PASS: a private key is caught as well as an access key\n'

# The pin is the rules: a different build is a different rule set, so a pass
# from one would not mean what the gate claims.
wrong_version="$TEST_ROOT/wrong-gitleaks"
printf '#!/bin/sh\nprintf "0.0.0\\n"\n' >"$wrong_version"
chmod +x "$wrong_version"
run_capture env -C "$scan_fixture" DOTFILES_GITLEAKS="$wrong_version" \
  ./scripts/scan-secrets.sh
assert_failure
assert_contains "$TEST_OUTPUT" "this repository pins $pinned_version"
printf 'PASS: a scanner that is not the pinned version is refused\n'

# --- The gate cannot be removed quietly ------------------------------------

# edit_workflow <old> <new>: one exact replacement in the fixture's
# validate.yml, refusing if <old> is not there, so a case that stops applying
# fails instead of silently testing the unmodified workflow.
edit_workflow() {
  python3 - "$tree/.github/workflows/validate.yml" "$1" "$2" <<'PYTHON'
import pathlib
import sys

workflow, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = workflow.read_text(encoding="utf-8")
if old not in text:
    raise SystemExit(f"the fixture workflow has no {old!r} to replace")
workflow.write_text(text.replace(old, new, 1), encoding="utf-8")
PYTHON
}

# drop_step <name>: the named step and nothing else.
drop_step() {
  python3 - "$tree/.github/workflows/validate.yml" "$1" <<'PYTHON'
import pathlib
import sys

workflow, name = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = workflow.read_text(encoding="utf-8").splitlines(keepends=True)
starts = [index for index, line in enumerate(lines) if line.strip() == f"- name: {name}"]
if len(starts) != 1:
    raise SystemExit(f"the fixture workflow has {len(starts)} steps named {name!r}")
start = starts[0]
indent = len(lines[start]) - len(lines[start].lstrip())
end = start + 1
while end < len(lines) and (
    not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) > indent
):
    end += 1
workflow.write_text("".join(lines[:start] + lines[end:]), encoding="utf-8")
PYTHON
}

# workflow_line <text>: the line number of <text> in the fixture's workflow,
# so a case can assert that a refusal names the line that disabled the gate.
workflow_line() {
  grep -nF -- "$1" "$tree/.github/workflows/validate.yml" | head -n 1 | cut -d: -f1
}


new_clean_tree
rm -f "$tree/scripts/scan-secrets.sh"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'scripts/scan-secrets.sh is missing'
printf 'PASS: deleting the scanner is refused\n'

new_clean_tree
drop_step 'Scan for committed credentials'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'never runs ./scripts/scan-secrets.sh'
printf 'PASS: deleting the CI step is refused\n'

# Commenting the step out is deleting it, which the line-by-line reader has to
# see: a `#` before the invocation is the cheapest way to disable a gate.
new_clean_tree
sed -i.bak 's|^        run: ./scripts/scan-secrets.sh|        # run: ./scripts/scan-secrets.sh|' \
  "$tree/.github/workflows/validate.yml"
rm -f "$tree/.github/workflows/validate.yml.bak"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'never runs ./scripts/scan-secrets.sh'
printf 'PASS: commenting the CI step out is refused\n'


# --- Every gate validate.yml relies on has to run, not just be named (#506) --
#
# Requiring the scanner's command *text* in the workflow left three one-line
# edits that disabled the step with the text still there: `if: false`,
# `continue-on-error: true`, and `--help`, which prints usage and exits 0.
# And the PowerShell analysis step had no requirement at all. Most cases below
# run against the real validate.yml, copied into the fixture, because a toy
# workflow that models the defect is the shape that hid it; the fixture's own
# workflow covers the shapes the real one does not have.
new_real_workflow_tree() {
  new_clean_tree
  cp "$repo_root/.github/workflows/validate.yml" "$tree/.github/workflows/validate.yml"
  cp "$repo_root/docs/testing.md" "$tree/docs/testing.md"
}

new_real_workflow_tree
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: the real validate.yml runs every required gate\n'

# Deleting a step, for each gate: the obvious mutation.
for gate in 'Scan for committed credentials=./scripts/scan-secrets.sh' \
  'Validate shell scripts=./scripts/lint.sh' \
  'Test bootstrap and installer behavior=./scripts/test.sh' \
  'Analyse every tracked PowerShell file=./tests/test-windows-static-analysis.ps1'; do
  new_clean_tree
  drop_step "${gate%%=*}"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" "never runs ${gate#*=}"
done
printf 'PASS: deleting any required step is refused, the PowerShell analysis included\n'

new_real_workflow_tree
drop_step 'Analyse every tracked PowerShell file'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'never runs ./tests/test-windows-static-analysis.ps1'
printf 'PASS: deleting the real PowerShell analysis step is refused\n'

# The subtle mutations: the step is still there, and still names the command.
new_real_workflow_tree
edit_workflow 'run: ./scripts/scan-secrets.sh' 'run: ./scripts/scan-secrets.sh --help'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'scan-secrets.sh --help'): the step passes \`--help\`"
printf 'PASS: a scanner step that only prints its usage is refused, naming the line\n'

new_real_workflow_tree
edit_workflow '      - name: Scan for committed credentials' \
  $'      - name: Scan for committed credentials\n        if: false'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'if: false'): the step carries \`if: false\`"
printf 'PASS: a scanner step switched off with if: false is refused, naming the line\n'

new_real_workflow_tree
edit_workflow '      - name: Scan for committed credentials' \
  $'      - name: Scan for committed credentials\n        continue-on-error: true'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'carries `continue-on-error: true`, so its failure is not one'
printf 'PASS: a scanner step whose failure is tolerated is refused\n'

new_real_workflow_tree
edit_workflow '    runs-on: windows-latest' \
  $'    runs-on: windows-latest\n    if: github.event_name == \'push\''
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "its job \`windows\` carries \`if: github.event_name == 'push'\`"
printf 'PASS: a job that skips pull requests cannot carry a required step\n'

new_real_workflow_tree
edit_workflow 'run: ./scripts/test.sh' 'run: ./scripts/test.sh || true'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'the step passes `|| true`'
printf 'PASS: a required command whose status is discarded is refused\n'

new_real_workflow_tree
edit_workflow '        run: ./scripts/scan-secrets.sh' \
  $'        run: |\n          exit 0\n          ./scripts/scan-secrets.sh'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'the step runs other commands in the same step'
printf 'PASS: a required command behind an earlier exit is refused\n'

# A custom shell template runs something else with the step's script as its
# argument; `true {0}` is a step that is present and does nothing.
new_real_workflow_tree
edit_workflow '        run: ./scripts/scan-secrets.sh' \
  $'        shell: true {0}\n        run: ./scripts/scan-secrets.sh'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'runs under `shell: true {0}`'
printf 'PASS: a required step under a shell that does not run it is refused\n'

# DOTFILES_GITLEAKS is how a workstation points the scanner at its own copy.
# In CI it would let any executable that prints the pinned version stand in.
new_real_workflow_tree
edit_workflow $'    env:\n      GIT_CONFIG_COUNT' $'    env:\n      DOTFILES_GITLEAKS: /usr/local/bin/gitleaks\n      GIT_CONFIG_COUNT'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" '`DOTFILES_GITLEAKS` is set, which replaces what the step runs'
printf 'PASS: a scanner pointed at another executable in CI is refused\n'

new_real_workflow_tree
edit_workflow $'  pull_request:\n' $'  pull_request:\n    paths-ignore:\n      - "**"\n'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'filters its pull_request trigger'
printf 'PASS: a workflow that some pull requests never trigger is refused\n'

new_clean_tree
edit_workflow $'  windows:\n    runs-on: windows-latest\n' \
  $'  gate:\n    if: false\n    runs-on: ubuntu-latest\n    steps:\n      - run: exit 0\n  windows:\n    needs: gate\n    runs-on: windows-latest\n'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'its job waits on `gate`, which carries `if: false`'
printf 'PASS: a required step behind a job that never runs is refused\n'

# What still counts as running it, so the rule pushes nobody into contortions:
# an explicit `continue-on-error: false`, the scanner's --range, an explicit
# interpreter, and an ordinary shell.
new_clean_tree
edit_workflow '        run: ./scripts/scan-secrets.sh' \
  $'        continue-on-error: false\n        run: ./scripts/scan-secrets.sh --range main..HEAD'
edit_workflow '        run: ./scripts/lint.sh' $'        shell: bash\n        run: bash ./scripts/lint.sh'
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a required step spelled differently but running for real is accepted\n'

new_clean_tree
rm -f "$tree/scripts/lint.sh"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'scripts/lint.sh is missing'
printf 'PASS: a required step calling a deleted command is refused\n'

# The workflow is read in the YAML subset it is written in, and a shape
# outside it is refused by line rather than read approximately.
for unreadable in 'steps: {}' 'steps: &shared'; do
  new_clean_tree
  edit_workflow '    steps:' "    $unreadable"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'refuses a shape it cannot read rather than guessing'
done
printf 'PASS: a workflow shape the reader cannot read is refused, not guessed at\n'

# --- gitleaks has no allowlist but .gitleaks.toml (#506) --------------------
#
# gitleaks also honours a `.gitleaksignore` fingerprint file in the scanned
# directory and a `gitleaks:allow` comment on a line. Neither is scoped or
# justified, and nothing in this repository knew either existed. The scanner
# refuses the file and switches the comment off; these use the same fixture
# and the same credential as the cases above.
printf 'aws_access_key_id = "%s%s"\n' 'AKIA' 'QYLPT5RZ2MJKF3WX' \
  >"$scan_fixture/config.ini"
printf 'config.ini:aws-access-token:1\n' >"$scan_fixture/.gitleaksignore"
scan_the_fixture
assert_failure
assert_contains "$TEST_OUTPUT" 'Refusing to scan: .gitleaksignore exists'
rm -f "$scan_fixture/.gitleaksignore"
printf 'PASS: a .gitleaksignore naming a credential in the tree does not silence it\n'

# The same exemption, spelled as the comment gitleaks honours on the line.
printf 'aws_access_key_id = "%s%s" # gitleaks:%s\n' 'AKIA' 'QYLPT5RZ2MJKF3WX' 'allow' \
  >"$scan_fixture/config.ini"
scan_the_fixture
assert_failure
assert_contains "$TEST_OUTPUT" 'A credential was found'
rm -f "$scan_fixture/config.ini"
printf 'PASS: a gitleaks:allow comment does not silence a credential\n'

# And lint refuses the file before a scan ever sees it, empty or not, and
# wherever it is tracked.
new_clean_tree
printf 'config.ini:aws-access-token:1\n' >"$tree/.gitleaksignore"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" '.gitleaksignore silences secret-scanner findings by fingerprint'
printf 'PASS: a .gitleaksignore at the root fails lint\n'

new_clean_tree
git -C "$tree" init -q
: >"$tree/docs/.gitleaksignore"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/.gitleaksignore silences secret-scanner findings'
printf 'PASS: an empty .gitleaksignore tracked anywhere fails lint\n'

# --- The scanner's rules are the defaults, all of them (#506) ---------------
#
# The credential cases above plant two shapes. Everything else the default
# rules cover could be allowlisted away in the narrow-looking,
# comment-justified style .gitleaks.toml prescribes, with every check green.
# So the real configuration is run over one generated sample per high-value
# rule family, and each has to be reported by its own rule. Every sample is
# assembled from parts at run time, for the reason given above.
drift_samples="$TEST_ROOT/drift-samples"
mkdir -p "$drift_samples"
printf 'aws_access_key_id = "%s%s"\n' 'AKIA' 'QYLPT5RZ2MJKF3WX' >"$drift_samples/aws.ini"
printf -- '-----BEGIN RSA PRIVATE %s-----\n%s\n-----END RSA PRIVATE %s-----\n' \
  'KEY' 'MIIEpAIBAAKCAQEA4Zx9qT2mVbN7cLrY8wKfDsEoQ1hJiUvXgPnMt6RaBw3ZkSyF' 'KEY' \
  >"$drift_samples/id_rsa"
printf 'token = "%s%s"\n' 'ghp_' 'R8kLm2Qw9ZxT4vB7nY1cD5fH3jK6pS0uE2aG' \
  >"$drift_samples/github.txt"
printf 'token = "%s%s"\n' 'github_pat_' \
  '11ABCDEFG0aB3cD5eF7gH9_jK2mN4pQ6rS8tU0vW2xY4zA6bC8dE0fG2hJ4kL6mN8pQ0rS2tU4vW6xY8zA0bC2dE4f' \
  >"$drift_samples/github-fine-grained.txt"
printf 'token = "%s%s"\n' 'glpat-' 'x9Qm2Lk7Wv4Rt8Zp1Nc6' >"$drift_samples/gitlab.txt"
printf 'SLACK_TOKEN = "%s%s"\n' 'xoxb-' '2718281828-3141592653589-Qm7vR2kLx9Tz4WpN8cB5yH1d' \
  >"$drift_samples/slack.txt"
printf 'stripe_key = "%s%s"\n' 'sk_live_' '51Hq8vKj2Lm9Wx4Rt7Zp1Nc6Bd3Fg5Hy8Jk' \
  >"$drift_samples/stripe.txt"
printf 'api_key = "%s%s"\n' 'AIza' 'SyB9x2Kq7Lm4Wv8Rt1Zp6Nc3Bd5Fg0Hy2Jk' >"$drift_samples/gcp.txt"
printf 'service_api_key = "%s"\n' 'q8Zr2Lk9Wv4Xt7Mp1Nc6Bd3Fg5Hy0Jk2Ls9' >"$drift_samples/generic.txt"
drift_rules='aws-access-token gcp-api-key generic-api-key github-fine-grained-pat github-pat gitlab-pat private-key slack-bot-token stripe-access-token'

# unreported_rules <config>: each sampled rule family that <config> no longer
# reports, space-separated, or nothing when every one is still caught.
unreported_rules() {
  local report="$TEST_ROOT/drift-report.json"
  rm -f "$report"
  "$gitleaks" dir "$drift_samples" --config "$1" --no-banner --redact \
    --report-format json --report-path "$report" --exit-code 0 >/dev/null 2>&1 ||
    _test_die "gitleaks could not scan the rule-family samples with $1"
  python3 - "$report" "$drift_rules" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report:
    found = {finding["RuleID"] for finding in json.load(report)}
print(" ".join(rule for rule in sys.argv[2].split() if rule not in found))
PYTHON
}

assert_eq '' "$(unreported_rules "$repo_root/.gitleaks.toml")" \
  'the tracked .gitleaks.toml must report every rule family sampled here'
printf 'PASS: the tracked scanner configuration reports every sampled rule family\n'

# The shape that defeated the gate: a narrow-looking allowlist for one family.
drifted="$TEST_ROOT/drifted.toml"
cp "$repo_root/.gitleaks.toml" "$drifted"
cat >>"$drifted" <<'EOF'

[[allowlists]]
description = "GitHub tokens in fixtures"
regexes = ['''ghp_[0-9a-zA-Z]{36}''']
EOF
assert_eq 'github-pat' "$(unreported_rules "$drifted")" \
  'an allowlist for one token shape must be seen to silence that family'
printf 'PASS: an allowlist that silences a rule family is caught by the drift control\n'

# The subtle one: no allowlist at all, a local rule reusing a default's ID.
cp "$repo_root/.gitleaks.toml" "$drifted"
cat >>"$drifted" <<'EOF'

[[rules]]
id = "slack-bot-token"
regex = '''x^'''
EOF
assert_eq 'slack-bot-token' "$(unreported_rules "$drifted")" \
  'a local rule overriding a default must be seen to silence that family'
printf 'PASS: a local rule overriding a default one is caught by the drift control\n'

# And the file's own two rules are executable: an exception is one anchored
# literal with a description, and nothing else may appear in the file.
gitleaks_config_case() {
  new_clean_tree
  cat >"$tree/.gitleaks.toml"
  run_capture python3 "$validator" --root "$tree"
}

gitleaks_config_case <<'EOF'
[extend]
useDefault = true

[[allowlists]]
description = "One fixture file and its one literal, neither a credential"
paths = ['''^tests/fixtures/sample\.txt$''']
regexes = ['''^not-a-credential-0001$''']
EOF
assert_success
printf 'PASS: an allowlist entry scoped to one literal is accepted\n'

gitleaks_config_case <<'EOF'
[extend]
useDefault = true

[[allowlists]]
description = "GitHub tokens in fixtures"
regexes = ['''ghp_[0-9a-zA-Z]{36}''']
EOF
assert_failure
assert_contains "$TEST_OUTPUT" "regexes entry 'ghp_[0-9a-zA-Z]{36}' matches more than one literal"
printf 'PASS: an unanchored allowlist pattern fails lint\n'

gitleaks_config_case <<'EOF'
[extend]
useDefault = true

[[allowlists]]
description = "GitHub tokens in fixtures"
regexes = ['''^ghp_[0-9a-zA-Z]{36}$''']
paths = ['''^tests/fixtures/''']
EOF
assert_failure
assert_contains "$TEST_OUTPUT" "regexes entry '^ghp_[0-9a-zA-Z]{36}\$' matches more than one literal"
assert_contains "$TEST_OUTPUT" "paths entry '^tests/fixtures/' matches more than one literal"
printf 'PASS: an anchored pattern class and a whole directory fail lint\n'

gitleaks_config_case <<'EOF'
[extend]
useDefault = true
disabledRules = ["slack-bot-token"]

[[rules]]
id = "gitlab-pat"
regex = '''x^'''

[[allowlists]]
description = "Anything mentioning fixture"
stopwords = ["fixture"]
EOF
assert_failure
assert_contains "$TEST_OUTPUT" '[extend] must be exactly `useDefault = true`'
assert_contains "$TEST_OUTPUT" '`rules` is not something'
assert_contains "$TEST_OUTPUT" 'sets `stopwords`, which is broader than one literal'
printf 'PASS: a disabled rule, an overriding rule and a stopword each fail lint\n'

# --- PowerShell paths are repository references too (#506) ------------------
#
# The reference check never opened a .psd1, and its path pattern ended in
# sh|py, so PSScriptAnalyzerSettings.psd1 named a suite that did not exist,
# twice, with lint green. The paths are assembled at run time for the reason
# the check_symlink cases give.
missing_suite="$(printf 'tests/%s.ps1' no-such-suite)"
missing_module="$(printf 'platforms/windows/%s.psm1' no-such-module)"

new_clean_tree
git -C "$tree" init -q
printf '@{\n    # Held by %s.\n}\n' "$missing_suite" >"$tree/Settings.psd1"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "Settings.psd1: names a repository path that does not exist: $missing_suite"
printf 'PASS: a PowerShell settings file naming a missing suite fails lint\n'

new_clean_tree
git -C "$tree" init -q
printf 'Import `%s` first.\n' "$missing_module" >"$tree/notes.md"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "notes.md: names a repository path that does not exist: $missing_module"
printf 'PASS: a missing PowerShell module named in prose fails lint\n'

new_clean_tree
git -C "$tree" init -q
printf '@{\n    # Held by %s.\n}\n' 'tests/test-windows-static-analysis.ps1' >"$tree/Settings.psd1"
git -C "$tree" add -A
run_capture python3 "$validator" --root "$tree"
assert_success
printf 'PASS: a PowerShell path that exists is accepted\n'

# --- A push to main keeps its run (#499) ------------------------------------
#
# Keyed on the ref with cancel-in-progress on, the merge that landed next
# cancelled the previous main commit's run, and 10 of the 40 main pushes
# up to 23 September 2026 kept only a cancelled one. Each case edits the real
# workflow, and the first restores the exact block main carried.
new_real_workflow_tree
edit_workflow "  group: validate-\${{ github.workflow }}-\${{ github.event_name == 'push' && github.sha || github.ref }}
  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
  "  group: validate-\${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line '  group: validate-'): concurrency \`group\` is"
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line '  cancel-in-progress: true'): concurrency \`cancel-in-progress\` is \`true\`"
printf 'PASS: the concurrency block that cancelled main runs is refused\n'

# Turning cancellation off still shares one pending slot per group, and GitHub
# cancels the pending run it replaces, so a ref-keyed group alone is refused.
new_real_workflow_tree
edit_workflow "github.event_name == 'push' && github.sha || github.ref }}" 'github.ref }}'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'concurrency `group` is `validate-${{ github.workflow }}-${{ github.ref }}`'
assert_not_contains "$TEST_OUTPUT" 'cancel-in-progress'
printf 'PASS: a ref-keyed group is refused even with cancellation limited to pull requests\n'

new_real_workflow_tree
edit_workflow '    timeout-minutes: 15' $'    timeout-minutes: 15\n    concurrency: cheatsheets'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'concurrency: cheatsheets'): job \`cheatsheets\` sets its own concurrency"
printf 'PASS: a job-level concurrency group is refused\n'

# A comment carrying the accepted text is not the value.
new_real_workflow_tree
edit_workflow "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
  "  # cancel-in-progress: \${{ github.event_name == 'pull_request' }}"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'concurrency `cancel-in-progress` is nothing'
printf 'PASS: the accepted value in a comment does not count\n'

# --- The required jobs are exactly the ones merging waits for (#538) ------
#
# REQUIRED_STEPS pins four commands, and neither `cheatsheets` nor `macos`
# carries one that `repository` or `windows` does not already satisfy. So
# `continue-on-error: true` or an `if:` on either, or a new `name:` that the
# branch rules no longer match, passed every check, and GitHub counts a skipped
# job as a passing required check. Each case edits the real validate.yml.

# drop_job <key>: that job, from its key to the next job or the end.
drop_job() {
  python3 - "$tree/.github/workflows/validate.yml" "$1" <<'PYTHON'
import pathlib
import sys

workflow, key = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = workflow.read_text(encoding="utf-8").splitlines(keepends=True)
starts = [index for index, line in enumerate(lines) if line == f"  {key}:\n"]
if len(starts) != 1:
    raise SystemExit(f"the fixture workflow has {len(starts)} jobs keyed {key!r}")
end = starts[0] + 1
while end < len(lines) and (not lines[end].strip() or lines[end].startswith("    ")):
    end += 1
workflow.write_text("".join(lines[:starts[0]] + lines[end:]), encoding="utf-8")
PYTHON
}

# edit_doc <old> <new>: one exact replacement in the fixture's docs/testing.md.
edit_doc() {
  python3 - "$tree/docs/testing.md" "$1" "$2" <<'PYTHON'
import pathlib
import sys

page, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = page.read_text(encoding="utf-8")
if old not in text:
    raise SystemExit(f"the fixture page has no {old!r} to replace")
page.write_text(text.replace(old, new, 1), encoding="utf-8")
PYTHON
}

new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' $'    name: Printable cheat sheets\n    continue-on-error: true'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'continue-on-error: true'): job \`cheatsheets\` carries \`continue-on-error: true\`, so its failure is not one"
printf 'PASS: a required job whose failure is tolerated is refused, naming the line\n'

# Tolerated only where it matters: on pull requests, the runs merging waits for.
new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' \
  $'    name: Printable cheat sheets\n    continue-on-error: ${{ github.event_name == \'pull_request\' }}'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'continue-on-error: ${{'): job \`cheatsheets\` carries \`continue-on-error: \${{ github.event_name == 'pull_request' }}\`"
printf 'PASS: a required job tolerated only on pull requests is refused\n'

new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' \
  $'    name: Printable cheat sheets\n    if: github.event_name != \'pull_request\''
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line "if: github.event_name != 'pull_request'"): job \`cheatsheets\` carries \`if: github.event_name != 'pull_request'\`, so it can be skipped"
printf 'PASS: a required job that skips pull requests is refused, naming the line\n'

# The job itself is clean; the one it waits on is not, so it is skipped with it.
new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' $'    name: Printable cheat sheets\n    needs: macos'
edit_workflow '    name: macOS 26 arm64 validation' \
  $'    name: macOS 26 arm64 validation\n    if: github.event_name == \'push\''
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "job \`cheatsheets\` waits on \`macos\`, which carries \`if: github.event_name == 'push'\`"
printf 'PASS: a required job behind a job that can be skipped is refused\n'

new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' '    name: Cheat sheets (informational)'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line 'name: Cheat sheets (informational)'): job \`cheatsheets\` is named \`Cheat sheets (informational)\`, not \`Printable cheat sheets\`"
printf 'PASS: renaming a required job is refused, naming the line\n'

# A rename the branch rule would not match, however small, and one carried
# through to docs/testing.md as well: the page agreeing is not the rule agreeing.
new_real_workflow_tree
edit_workflow '    name: Printable cheat sheets' '    name: Printable Cheat Sheets'
edit_doc '`Printable cheat sheets`' '`Printable Cheat Sheets`'
edit_doc '`cheatsheets` (Printable cheat sheets)' '`cheatsheets` (Printable Cheat Sheets)'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'job `cheatsheets` is named `Printable Cheat Sheets`, not `Printable cheat sheets`'
printf 'PASS: a case-only rename, even one the page follows, is refused\n'

new_real_workflow_tree
drop_job macos
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" '.github/workflows/validate.yml has no job `macos` (`macOS 26 arm64 validation`)'
printf 'PASS: deleting a required job is refused by name\n'

new_real_workflow_tree
edit_workflow $'  windows:\n' $'  extra:\n    name: Extra\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n\n  windows:\n'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" ".github/workflows/validate.yml:$(workflow_line '  extra:'): job \`extra\` is not one of REQUIRED_JOBS"
printf 'PASS: a job merging does not wait for is refused\n'

# The page is held to the same names, so it cannot drift from the workflow.
new_real_workflow_tree
edit_doc '`Printable cheat sheets`,' '`Cheat sheets`,'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/testing.md: the paragraph on merge rules does not name `Printable cheat sheets`'
printf 'PASS: a merge-rules paragraph naming another check is refused\n'

new_real_workflow_tree
edit_doc '`macos` (macOS 26 arm64 validation)' '`macos` (macOS arm64 validation)'
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/testing.md: the job table names `macos` as `macOS arm64 validation`, not `macOS 26 arm64 validation`'
printf 'PASS: a job table naming a job differently is refused\n'

printf '\nAll repository hygiene checks passed.\n'
