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
  mkdir -p "$tree/docs/reference" "$tree/LICENSES" "$tree/vendor"
  printf 'MIT License\n' >"$tree/LICENSES/Upstream.txt"
  printf 'vendored\n' >"$tree/vendor/thing.conf"
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
assert_contains "$TEST_OUTPUT" '`git diff --check` with no range inspects the working tree'
printf 'PASS: a whitespace check with no range is rejected\n'

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

printf '\nAll repository hygiene checks passed.\n'
