#!/usr/bin/env bash
# Compatibility wrappers, file-mode policy and responsibility-revealing names
# (#161).
#
# The wrappers still work. That is the whole point of a deprecation window, so
# the tests below prove forwarding *and* the warning, not one or the other.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

roles="$repo_root/config/shell-file-roles.tsv"

# --- The deprecated wrappers still forward, and say so ----------------------

# Every deprecated Fedora wrapper, with the platform script it forwards to.
deprecated_wrappers() {
  local wrapper target
  for wrapper in "$repo_root"/scripts/*.sh; do
    grep -Fq 'deprecated_wrapper "' "$wrapper" || continue
    # shellcheck disable=SC2016 # The sed script matches literal shell text.
    target="$(sed -n 's|^exec "\$repo_root/\(.*\)" "\$@"$|\1|p' "$wrapper")"
    printf '%s\t%s\n' "${wrapper##*/}" "$target"
  done
}

count=0
while IFS=$'\t' read -r name target; do
  wrapper="$repo_root/scripts/$name"
  [[ -n "$target" ]] || _test_die "scripts/$name declares no forwarding target"
  [[ -f "$repo_root/$target" ]] ||
    _test_die "scripts/$name forwards to a path that does not exist: $target"
  [[ -x "$wrapper" ]] || _test_die "scripts/$name must stay executable while deprecated"
  count=$((count + 1))
done < <(deprecated_wrappers)
((count >= 20)) || _test_die "expected the full set of deprecated wrappers, found $count"
printf 'PASS: all %d deprecated wrappers forward to a real target\n' "$count"

# A wrapper whose target is a dry-run-capable installer is the cheapest honest
# end-to-end check: it proves the arguments reach the platform script.
test_new_root
run_capture env \
  "HOME=$TEST_ROOT/home" \
  "XDG_CONFIG_HOME=$TEST_ROOT/config" \
  "XDG_DATA_HOME=$TEST_ROOT/data" \
  "$repo_root/scripts/install-containers.sh" --dry-run
assert_success
assert_contains "$TEST_OUTPUT" "DEPRECATED"
assert_contains "$TEST_OUTPUT" "scripts/install-containers.sh is a compatibility wrapper"
assert_contains "$TEST_OUTPUT" "./install.sh --platform fedora --containers"
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/install-containers.sh"
assert_contains "$TEST_OUTPUT" "removed no earlier than"
printf 'PASS: a deprecated wrapper forwards its arguments and warns once\n'

# The notice must not reach stdout, or it corrupts a caller parsing output.
stdout_only="$(
  env "HOME=$TEST_ROOT/home" "XDG_CONFIG_HOME=$TEST_ROOT/config" \
    "XDG_DATA_HOME=$TEST_ROOT/data" \
    "$repo_root/scripts/install-containers.sh" --dry-run 2>/dev/null
)"
if grep -Fq 'DEPRECATED' <<<"$stdout_only"; then
  _test_die 'the deprecation notice must go to stderr, not stdout'
fi
printf 'PASS: the notice is on stderr, leaving stdout usable\n'

# Scripted callers can silence it.
run_capture env \
  "HOME=$TEST_ROOT/home" \
  "XDG_CONFIG_HOME=$TEST_ROOT/config" \
  "XDG_DATA_HOME=$TEST_ROOT/data" \
  DOTFILES_SUPPRESS_DEPRECATION=1 \
  "$repo_root/scripts/install-containers.sh" --dry-run
assert_success
assert_not_contains "$TEST_OUTPUT" "DEPRECATED"
printf 'PASS: DOTFILES_SUPPRESS_DEPRECATION silences the notice\n'

# Each wrapper names its own path, not a copy-pasted one.
while IFS=$'\t' read -r name target; do
  grep -Fq "deprecated_wrapper \"scripts/$name\"" "$repo_root/scripts/$name" ||
    _test_die "scripts/$name announces a different path than its own"
done < <(deprecated_wrappers)
printf 'PASS: every wrapper announces its own path\n'

# --- The window is one decision, in one place -------------------------------

assert_file_contains "$repo_root/common/lib/deprecation.sh" 'DOTFILES_DEPRECATION_REMOVAL_DATE='
removal_date="$(
  sed -n 's/^DOTFILES_DEPRECATION_REMOVAL_DATE="\(.*\)"$/\1/p' \
    "$repo_root/common/lib/deprecation.sh"
)"
[[ "$removal_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
  _test_die "the removal milestone must be an ISO date, got '$removal_date'"
if [[ "$removal_date" < "$(date -u +%F)" ]]; then
  _test_die "the deprecation window has expired ($removal_date); removal is now a separate change"
fi
for wrapper in "$repo_root"/scripts/*.sh; do
  grep -Fq 'deprecated_wrapper "' "$wrapper" || continue
  grep -Fq "$removal_date" "$wrapper" &&
    _test_die "${wrapper##*/} hard-codes the removal date instead of sharing one constant"
done
printf 'PASS: the removal milestone (%s) lives in exactly one place\n' "$removal_date"

# --- Portable wrappers are not deprecated -----------------------------------

for portable in install-ai install-mise install-neovim-tools install-tmux-theme verify-ai; do
  wrapper="$repo_root/scripts/$portable.sh"
  [[ -f "$wrapper" ]] || _test_die "scripts/$portable.sh is missing"
  if grep -Fq 'deprecated_wrapper' "$wrapper"; then
    _test_die "scripts/$portable.sh forwards to a portable common/ script and must not be deprecated"
  fi
  grep -Fq 'common/' "$wrapper" ||
    _test_die "scripts/$portable.sh must forward to its common/ implementation"
done
printf 'PASS: portable aliases for common/ scripts are not marked deprecated\n'

# --- File-mode policy -------------------------------------------------------

run_capture python3 "$repo_root/scripts/validate-shell-file-roles.py"
assert_success
printf 'PASS: every tracked shell file matches its declared role and mode\n'

test_new_root
tree="$TEST_ROOT/modes"
mkdir -p "$tree"
# A plain copy, rather than git archive piped through tar: the validation
# container is minimal and this needs no tool beyond cp. `cp -a` is required
# because this fixture is about file modes, and it also carries the source
# directory's ownership onto the copy — which, in a container running as a
# different user than the checkout, is exactly what git calls dubious
# ownership. The copied .git is replaced by a fresh one, and every git call
# against the copy declares it safe explicitly rather than depending on whose
# uid happens to own a temporary directory.
cp -a "$repo_root/." "$tree/"
rm -rf -- "$tree/.git"
fixture_git=(env "GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=safe.directory"
  "GIT_CONFIG_VALUE_0=$tree")
"${fixture_git[@]}" git -C "$tree" init --quiet
"${fixture_git[@]}" git -C "$tree" add -A

chmod +x "$tree/common/lib/common.sh"
run_capture "${fixture_git[@]}" python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "common/lib/common.sh"
assert_contains "$TEST_OUTPUT" "requires 644"
printf 'PASS: an executable sourced library fails the mode policy\n'

chmod -x "$tree/common/lib/common.sh" "$tree/install.sh"
run_capture "${fixture_git[@]}" python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "install.sh"
assert_contains "$TEST_OUTPUT" "requires 755"
printf 'PASS: a non-executable entry point fails the mode policy\n'

chmod +x "$tree/install.sh"
printf '#!/usr/bin/env bash\n' >"$tree/unclassified-script.sh"
"${fixture_git[@]}" git -C "$tree" add unclassified-script.sh
run_capture "${fixture_git[@]}" python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "no role in"
printf 'PASS: a shell file no role claims fails, so classifying it is unavoidable\n'

# The `scripts/*.sh` catch-all claims every new helper as a deprecated wrapper.
# A file it claims must actually be one, or the inventory describes it -- in
# the authoritative place -- as scheduled for removal.
rm -f "$tree/unclassified-script.sh"
"${fixture_git[@]}" git -C "$tree" rm --cached --quiet unclassified-script.sh
# The name is assembled rather than written out, so repository-hygiene
# validation does not read this file as naming a script that does not exist.
helper_name="summarize-${TEST_HELPER_SUFFIX:-profile-state}.sh"
helper="$tree/scripts/$helper_name"
cat >"$helper" <<'EOF_HELPER'
#!/usr/bin/env bash
set -euo pipefail
true
EOF_HELPER
chmod 755 "$helper"
"${fixture_git[@]}" git -C "$tree" add "scripts/$helper_name"
run_capture "${fixture_git[@]}" python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$tree"
assert_failure
assert_contains "$TEST_OUTPUT" "scripts/$helper_name"
assert_contains "$TEST_OUTPUT" "never calls deprecated_wrapper"
printf 'PASS: a new scripts/ helper is not silently classified as a deprecated wrapper\n'

cat >"$helper" <<EOF_HELPER
#!/usr/bin/env bash
set -euo pipefail
deprecated_wrapper "scripts/$helper_name"
EOF_HELPER
run_capture "${fixture_git[@]}" python3 "$repo_root/scripts/validate-shell-file-roles.py" --root "$tree"
assert_success
printf 'PASS: a real wrapper still passes under the same catch-all\n'
rm -f "$helper"
"${fixture_git[@]}" git -C "$tree" rm --cached --quiet "scripts/$helper_name"

# --- Responsibility-revealing names, with no stale references ---------------

# Only the two paths that no longer exist are searched for. The surviving
# shim under scripts/lib keeps its old name on purpose — that is what a
# compatibility path is — so matching the bare filename would flag every file
# that correctly mentions it. The removed paths are assembled at run time
# rather than written out, so this file does not match its own search.
legacy="theme-${TEST_LEGACY_SUFFIX:-state}.sh"

assert_path_exists "$repo_root/common/lib/theme-shared-state.sh"
assert_path_exists "$repo_root/platforms/fedora/lib/theme-desktop.sh"
assert_path_missing "$repo_root/common/lib/$legacy"
assert_path_missing "$repo_root/platforms/fedora/lib/$legacy"

stale=0
while IFS= read -r -d '' tracked; do
  case "$tracked" in *.sh | *.md | *.zsh | *.py | *.tsv) ;; *) continue ;; esac
  for removed in "common/lib/$legacy" "platforms/fedora/lib/$legacy"; do
    if grep -Fq "$removed" "$repo_root/$tracked"; then
      printf 'FAIL: %s still references the renamed %s\n' "$tracked" "$removed" >&2
      stale=$((stale + 1))
    fi
  done
done < <(git -C "$repo_root" ls-files -z)
((stale == 0)) || _test_die "$stale stale reference(s) to a renamed theme library"
printf 'PASS: the renamed theme libraries have no stale references\n'

run_capture python3 "$repo_root/scripts/validate-repository-hygiene.py"
assert_success
printf 'PASS: no tracked file names a repository script that does not exist\n'

# The deprecated sourced shim still provides what it always did.
# shellcheck disable=SC2016 # The payload expands in the child bash, not here.
run_capture bash -c '
  set -euo pipefail
  DOTFILES_SUPPRESS_DEPRECATION=1
  export DOTFILES_SUPPRESS_DEPRECATION
  source "$1/common/lib/common.sh"
  source "$1/scripts/lib/theme-state.sh"
  declare -F write_theme_state >/dev/null
' bash "$repo_root"
assert_success
printf 'PASS: the deprecated theme-state shim still provides write_theme_state\n'

# shellcheck disable=SC2016 # The payload expands in the child bash, not here.
run_capture bash -c '
  set -euo pipefail
  source "$1/scripts/lib/theme-state.sh" 2>&1 >/dev/null | grep -Fq DEPRECATED
' bash "$repo_root"
assert_success
printf 'PASS: sourcing the deprecated shim warns\n'

# --- Documentation distinguishes the kinds of entry point -------------------

conventions="$repo_root/docs/architecture/repository-conventions.md"
for phrase in 'Portable entry point' 'Platform command' 'Portable wrapper' \
  'Deprecated compatibility wrapper' 'Internal implementation'; do
  assert_file_contains "$conventions" "$phrase"
done
assert_file_contains "$conventions" 'theme-shared-state.sh'
assert_file_contains "$conventions" 'theme-desktop.sh'
printf 'PASS: documentation separates portable, platform, deprecated and internal paths\n'

# The role manifest is the inventory the documentation claims it is.
for role in public-entrypoint platform-entrypoint internal-executable \
  portable-wrapper deprecated-wrapper sourced-library stowed-command \
  stowed-config test-entrypoint; do
  grep -q "^$role	" "$roles" || _test_die "config/shell-file-roles.tsv has no $role rows"
done
printf 'PASS: every documented role exists in the inventory\n'

printf '\nAll compatibility wrapper, mode and naming checks passed.\n'
