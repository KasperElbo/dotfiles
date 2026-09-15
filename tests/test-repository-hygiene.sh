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

printf '\nAll repository hygiene checks passed.\n'
