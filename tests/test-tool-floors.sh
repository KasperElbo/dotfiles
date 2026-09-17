#!/usr/bin/env bash
# The one place a dependency version floor is stated, and its enforcement.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/tool-floors.sh
source "$repo_root/common/lib/tool-floors.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# --- The registry answers, and a name it does not know is an error ----------

assert_eq 0.12 "$(tool_floor nvim)" 'the Neovim floor comes from the registry'
assert_eq 3.11 "$(tool_floor python3)" 'the Python floor comes from the registry'
run_capture tool_floor definitely-not-a-tool
assert_failure
assert_contains "$TEST_OUTPUT" 'No version floor is declared for definitely-not-a-tool'

# --- Version comparison -----------------------------------------------------

version_at_least 0.12.5 0.12 || _test_die '0.12.5 must satisfy the 0.12 floor'
version_at_least 0.12 0.12 || _test_die '0.12 must satisfy the 0.12 floor'
version_at_least 1.0 0.12 || _test_die '1.0 must satisfy the 0.12 floor'
if version_at_least 0.9.5 0.12; then
  _test_die '0.9.5 must not satisfy the 0.12 floor'
fi
if version_at_least v0.12 0.12; then
  _test_die 'a version that is not dotted digits must never satisfy a floor'
fi

# --- The check names the tool, the version found, and the floor -------------

stub_bin="$root/stub-bin"
mkdir -p "$stub_bin"
stub_nvim() {
  cat >"$stub_bin/nvim" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] || exit 0
printf '%s\n' '$1'
EOF
  chmod +x "$stub_bin/nvim"
}
check_stubbed_nvim() {
  run_capture env PATH="$stub_bin:$PATH" \
    bash -c 'set -uo pipefail; source "$1"; tool_floor_check nvim' floors \
    "$repo_root/common/lib/tool-floors.sh"
}

stub_nvim 'NVIM v0.9.5'
check_stubbed_nvim
assert_failure
assert_contains "$TEST_OUTPUT" \
  'nvim 0.9.5 is older than the required 0.12 (config/tool-floors.tsv)'

stub_nvim 'NVIM v0.12.5'
check_stubbed_nvim
assert_success

stub_nvim 'not a version banner'
check_stubbed_nvim
assert_failure
assert_contains "$TEST_OUTPUT" 'nvim did not report a usable version'

# --- The validator holds the registry, the docs and the enforcers together --

run_capture python3 "$repo_root/scripts/validate-tool-floors.py"
assert_success

# Raising the floor must fail the build until every page that states it agrees,
# not only the contributor-toolchain table: three pages stating two different
# Neovim minimums is the state this registry replaced.
raised="$root/raised-floors.tsv"
sed 's/^nvim\t0.12\t/nvim\t0.13\t/' "$repo_root/config/tool-floors.tsv" >"$raised"
run_capture env TOOL_FLOOR_MANIFEST="$raised" \
  python3 "$repo_root/scripts/validate-tool-floors.py"
assert_failure
for page in docs/testing.md docs/workflows/editor.md docs/platforms/README.md; do
  assert_contains "$TEST_OUTPUT" "$page:"
done
assert_contains "$TEST_OUTPUT" 'states 0.12 as the nvim minimum'
assert_contains "$TEST_OUTPUT" \
  'docs/testing.md does not state the nvim floor (0.13)'

# A pinned version is not a floor: the pages that name the Parrot mise pin must
# not be dragged into the disagreement above.
assert_not_contains "$TEST_OUTPUT" 'docs/platforms/parrot-ctf.md'
assert_not_contains "$TEST_OUTPUT" 'docs/architecture/package-ownership.md'

# One line may state a floor for several tools, and each number belongs to the
# tool it is written after: comparing every tool named on a line against every
# version on it would refuse correct prose.
fixture="$root/multi-tool-page"
mkdir -p "$fixture/config" "$fixture/docs" "$fixture/docs/workflows"
printf 'tool_floor_check nvim\ntool_floor_check python3\n' >"$fixture/enforce.sh"
{
  printf 'tool\tmin_version\trequirement\tconsumers\n'
  printf 'nvim\t0.12\tThe tracked configuration requires it\tenforce.sh\n'
  printf 'python3\t3.11\tEvery validator targets it\tenforce.sh\n'
} >"$fixture/config/tool-floors.tsv"
{
  printf '| Tool | Minimum version | Used by |\n'
  printf '| --- | --- | --- |\n'
  printf '| Neovim (`nvim`) | >= 0.12 | the editor suites |\n'
  printf '| Python 3 (`python3`) | >= 3.11 | every validator |\n'
} >"$fixture/docs/testing.md"
requirements="$fixture/docs/workflows/editor.md"
# The second line states a floor for a plugin whose name ends in the registry
# tool's name; a substring match would read it as a stale Neovim minimum.
write_requirements() {
  printf -- '- Neovim %s and Python 3.11+ are required\n' "$1" >"$requirements"
  printf -- '- lazy.nvim pins nvim-treesitter 0.25+ for the editor profile\n' \
    >>"$requirements"
  git -C "$fixture" add -A
}
git init -q "$fixture"
write_requirements '0.12+'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# A stale floor on that same line is still caught, and only for its own tool.
write_requirements '0.11+'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/workflows/editor.md:1 states 0.11 as the nvim minimum'
assert_not_contains "$TEST_OUTPUT" 'as the python3 minimum'
assert_not_contains "$TEST_OUTPUT" '0.25'

# A consumer that stops reading the registry is a floor free to drift again.
unenforced="$root/unenforced-floors.tsv"
printf 'tool\tmin_version\trequirement\tconsumers\n' >"$unenforced"
printf 'nvim\t0.12\tThe tracked configuration requires it\tREADME.md\n' >>"$unenforced"
run_capture env TOOL_FLOOR_MANIFEST="$unenforced" \
  python3 "$repo_root/scripts/validate-tool-floors.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'README.md is named as enforcing the nvim floor but never reads it'

printf 'Tool version-floor registry, reader and enforcement tests passed.\n'
