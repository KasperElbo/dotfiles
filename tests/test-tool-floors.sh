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

# The pin itself is held to the raised floor, so the Parrot guest cannot keep
# provisioning a Neovim the registry no longer accepts.
assert_contains "$TEST_OUTPUT" \
  'platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml pins nvim'

# The same holds for the pin whose mise key is not the registry's tool name:
# the workstation mise configuration pins `python`, the registry row is
# `python3`, and raising that floor must name the pin rather than pass.
raised_python="$root/raised-python-floors.tsv"
sed 's/^python3\t3.11\t/python3\t3.99\t/' "$repo_root/config/tool-floors.tsv" \
  >"$raised_python"
run_capture env TOOL_FLOOR_MANIFEST="$raised_python" \
  python3 "$repo_root/scripts/validate-tool-floors.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'mise/.config/mise/config.toml pins python '
assert_contains "$TEST_OUTPUT" 'requires python3 3.99 or newer'

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

# Prose here is hard-wrapped, so a stated minimum belongs to the paragraph that
# names the tool, not to the physical line the number landed on: a reword that
# pushes the floor onto the next line must not drop the check.
write_wrapped_requirement() {
  {
    printf -- 'Neovim is owned by whatever native provider the platform already\n'
    printf -- 'uses, and the tracked configuration requires %s.\n' "$1"
  } >"$requirements"
  git -C "$fixture" add -A
}
write_wrapped_requirement '0.12 or newer'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

write_wrapped_requirement '0.11 or newer'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/workflows/editor.md:2 states 0.11 as the nvim minimum'

# A minimum a paragraph states before naming any registry tool is an error, not
# a silently dropped check: dropping it is what turns this into false assurance.
{
  printf -- 'The tracked configuration requires 0.12 or newer, which the Neovim\n'
  printf -- 'each supported platform packages already satisfies.\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'docs/workflows/editor.md:1 states a 0.12 minimum before naming the tool'

# A floor for something the registry does not track is left alone; the pages
# state minimums for a kernel and a system Bash that this registry never owns.
{
  printf -- '- the hardware installer requires a kernel of at least 7.1\n'
  printf -- '- the entry point re-executes with Bash 4.4 or newer\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# The one version this repository actually controls is the mise pin, so it is
# held to the registry too: raising a floor above the pin must fail the build
# rather than leave a machine provisioning less than the floor demands.
pin_nvim() {
  mkdir -p "$fixture/mise/.config/mise"
  printf '[tools]\nnvim = %s\nuv = "latest"\n' "$1" \
    >"$fixture/mise/.config/mise/config.toml"
  git -C "$fixture" add -A
}
write_wrapped_requirement '0.12 or newer'
pin_nvim '{ version = "0.12.5", bin_path = "bin" }'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

pin_nvim '"0.11.9"'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'mise/.config/mise/config.toml pins nvim 0.11.9; tool-floors.tsv requires nvim 0.12 or newer'

# A pin that names no version cannot drift below a floor and is not an error.
pin_nvim '"latest"'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# mise names a tool the way the toolchain table labels it, which is not always
# the command name the registry keys on: `Python 3` is pinned as `python`.
pin_python() {
  mkdir -p "$fixture/mise/.config/mise"
  printf '[tools]\npython = "%s"\nuv = "latest"\n' "$1" \
    >"$fixture/mise/.config/mise/config.toml"
  git -C "$fixture" add -A
}
pin_python '3.14'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

pin_python '3.10'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'mise/.config/mise/config.toml pins python 3.10; tool-floors.tsv requires python3 3.11 or newer'

# mise resolves a short pin to the newest version that starts with it, so a pin
# is a prefix and not an exact version. `python = "3"` provisions the newest
# 3.x, which is at or above a 3.11 floor; reading it as 3.0 refused a pin that
# is correct, and this repository already pins `dotnet` and `node` that way.
pin_python '3'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# The prefix still cannot reach above itself: every 3.10.x is below 3.11.
pin_python '3.10'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure

# mise's explicit marker for the same thing.
pin_python 'prefix:3'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# --- A backend-qualified key is the same tool ------------------------------

# An ordinary edit can move a pin to a backend-qualified key, which is already
# this repository's style elsewhere in the same file. The floor must follow it
# there, because a key that quietly leaves the check's scope is the failure
# this check exists to prevent: a floor nobody enforces, reported as success.
pin_key() {
  mkdir -p "$fixture/mise/.config/mise"
  printf '[tools]\n"%s" = "%s"\nuv = "latest"\n' "$1" "$2" \
    >"$fixture/mise/.config/mise/config.toml"
  git -C "$fixture" add -A
}
pin_key 'core:python' '3.10'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'pins core:python 3.10; tool-floors.tsv requires python3 3.11 or newer'

# A backend that names a repository resolves to the tool the repository builds.
pin_key 'github:neovim/neovim' '0.11.9'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'pins github:neovim/neovim 0.11.9; tool-floors.tsv requires nvim 0.12 or newer'

# A language-ecosystem backend names a package, not the tool: the npm package
# `neovim` is Neovim's Node client on its own version line, so holding it to
# Neovim's floor would check the wrong artefact and refuse a correct pin.
pin_key 'npm:neovim' '5.3.0'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# A backend the check has never been taught is neither of those, so it is an
# error rather than a silent third case: guessing either way is a wrong answer
# given without saying so.
pin_key 'notabackend:python' '3.14'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'pins notabackend:python through the notabackend mise backend'

# --- A pin the check cannot read is an error, not a skip -------------------

# Skipping what it does not understand is how this check would fail open, so a
# pin it cannot interpret fails the build and names the tool left unenforced.
pin_python 'ref:main'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" "pins python 'ref:main', which this check cannot read"
assert_contains "$TEST_OUTPUT" 'a python3 floor nothing enforces'

# The same for a table that carries options but never a version.
mkdir -p "$fixture/mise/.config/mise"
printf '[tools]\npython = { backend = "core" }\n' \
  >"$fixture/mise/.config/mise/config.toml"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'which this check cannot read'

# A version written as a TOML number rather than a string is not a version mise
# would accept either, and is named rather than dropped.
printf '[tools]\npython = 3\n' >"$fixture/mise/.config/mise/config.toml"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'which this check cannot read'

# --- Raising a floor names every stale pin, in every spelling --------------

mkdir -p "$fixture/mise/.config/mise"
cat >"$fixture/mise/.config/mise/config.toml" <<'EOF_PINS'
[tools]
nvim = "0.11.9"
"github:neovim/neovim" = "0.11"
python = "3.10"
"core:python" = "3"
"npm:neovim" = "5.3.0"
uv = "latest"
EOF_PINS
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'pins nvim 0.11.9'
assert_contains "$TEST_OUTPUT" 'pins github:neovim/neovim 0.11'
assert_contains "$TEST_OUTPUT" 'pins python 3.10'
# The package and the prefix that does reach the floor are the controls: naming
# them would mean the check refuses pins that are correct.
assert_not_contains "$TEST_OUTPUT" 'pins core:python'
assert_not_contains "$TEST_OUTPUT" 'npm:neovim'

# The fixture mise configuration a caller's unrelated project would carry is
# not one this repository provisions, so its pins are none of the validator's
# business even when they name a registry tool.
mkdir -p "$fixture/tests/fixtures/unrelated-project"
printf '[tools]\nnvim = "0.9.0"\n' \
  >"$fixture/tests/fixtures/unrelated-project/.mise.toml"
pin_python '3.14'
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

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
