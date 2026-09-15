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

printf '\nAll repository hygiene checks passed.\n'
