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
  # The secret-scanning gate: a tree without it, or with a workflow that never
  # runs it, is a defect of its own, so the clean fixture carries both.
  printf '#!/usr/bin/env bash\n' >"$tree/scripts/scan-secrets.sh"
  cat >"$tree/.github/workflows/validate.yml" <<'EOF'
name: Validate
jobs:
  repository:
    steps:
      - name: Scan for committed credentials
        run: ./scripts/scan-secrets.sh
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
assert_contains "$TEST_OUTPUT" 'names no commit range'
printf 'PASS: a whitespace check with no range is rejected\n'

# The rule is "names a range", not "has an argument". These are the two forms
# someone reaches for on being told the bare form is not enough, and both
# compare something a runner cannot dirty: --cached compares the index to HEAD,
# identical after actions/checkout, and a lone pathspec compares the working
# tree to the index.
for vacuous in '--cached' '--staged' '-- .' 'HEAD'; do
  new_workflow_tree
  sed -i "s|run: git diff --check .*|run: git diff --check $vacuous|" \
    "$tree/.github/workflows/example.yml"
  run_capture python3 "$validator" --root "$tree"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'names no commit range'
done
printf 'PASS: an argument that compares nothing is rejected as no range\n'

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

new_clean_tree
rm -f "$tree/scripts/scan-secrets.sh"
run_capture python3 "$validator" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" 'scripts/scan-secrets.sh is missing'
printf 'PASS: deleting the scanner is refused\n'

new_clean_tree
python3 - "$tree/.github/workflows/validate.yml" <<'PYTHON'
import pathlib
import sys

workflow = pathlib.Path(sys.argv[1])
text = workflow.read_text(encoding="utf-8")
marker = "      - name: Scan for committed credentials\n"
if marker not in text:
    raise SystemExit("the fixture workflow has no scanner step to remove")
workflow.write_text(text[: text.index(marker)], encoding="utf-8")
PYTHON
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

printf '\nAll repository hygiene checks passed.\n'
