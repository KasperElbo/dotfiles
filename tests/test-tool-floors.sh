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
# state minimums for a kernel and an operating system this registry never owns.
# (Bash was a third until its floor joined the registry, #539.)
{
  printf -- '- the hardware installer requires a kernel of at least 7.1\n'
  printf -- '- the dictation app runs on macOS 14.0+ only\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# A paragraph that states a floor and names no tool used to be skipped without a
# word, so a floor whose tool was named anywhere but in its own sentence went
# unchecked (#508, V4-09). The obvious shape: the section heading names the tool.
{
  printf -- '## Neovim\n\n'
  printf -- 'This toolchain requires 0.9 or newer.\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/workflows/editor.md:3 states 0.9 as the nvim minimum'

# ...and the right floor under that heading still passes, so the heading is read
# as the tool it names rather than as a reason to refuse.
{
  printf -- '## Neovim\n\n'
  printf -- 'This toolchain requires 0.12 or newer.\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_success

# The subtle shape: the tool is named in a table row, and the sentence below it
# says only "it". Nothing ties that sentence to the row, so it is reported
# rather than guessed at either way.
{
  printf -- '| Tool | Notes |\n'
  printf -- '| --- | --- |\n'
  printf -- '| Neovim (`nvim`) | the editor |\n\n'
  printf -- 'It requires 0.9 or newer.\n'
} >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'docs/workflows/editor.md:5 states a 0.9 minimum without naming the tool it is for'

# An untracked subject is one written directly before the number. Naming macOS
# earlier in a sentence about Neovim does not make Neovim's floor macOS's.
printf -- 'Neovim on macOS requires 0.9 or newer.\n' >"$requirements"
git -C "$fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$fixture"
assert_failure
assert_contains "$TEST_OUTPUT" 'docs/workflows/editor.md:1 states 0.9 as the nvim minimum'

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

# --- Enforcement is read as shell, not matched as text ----------------------

# The check this replaces matched the reader's name with a regex, which a
# comment naming the function satisfied on its own. Deleting the real call
# from a consumer and leaving the comment beside it kept the build green with
# no floor enforced anywhere, so each way a name can appear without being run
# gets its own case here.
reading="$root/reading-as-shell"
mkdir -p "$reading/config" "$reading/docs"
{
  printf 'tool\tmin_version\trequirement\tconsumers\n'
  printf 'nvim\t0.12\tThe tracked configuration requires it\tenforce.sh\n'
} >"$reading/config/tool-floors.tsv"
{
  printf '| Tool | Minimum version | Used by |\n'
  printf '| --- | --- | --- |\n'
  printf '| Neovim (`nvim`) | >= 0.12 | the editor suites |\n'
} >"$reading/docs/testing.md"
git init -q "$reading"

# Each case writes one consumer and says whether the floor is enforced by it.
write_consumer() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$reading/enforce.sh"
  git -C "$reading" add -A
  run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$reading"
}
unenforced_message='enforce.sh is named as enforcing the nvim floor but never reads it'

write_consumer 'tool_floor_check nvim'
assert_success

# The exact shape the old check could not tell apart: the call is gone and only
# the comment that described it remains.
write_consumer '# The reason is tool_floor_check'"'"'s to state -- below the floor or older
: no floor is enforced here'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

write_consumer '# tool_floor_check nvim'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

write_consumer 'printf "run tool_floor_check nvim to check"'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# A reader in a function nothing calls enforces as little as one in a comment.
write_consumer 'never_called() {
  tool_floor_check nvim
}
: done'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# ...and the same function, once something calls it, does enforce it.
write_consumer 'called() {
  tool_floor_check nvim
}
called'
assert_success

# Where the brace sits is a spelling, not a statement about whether the body
# runs. The reader this check used to carry recognised a definition only with
# the brace on the same line, so the identical uncalled function passed when
# the brace moved down a line and its floor check counted as load-time code.
write_consumer 'never_called()
{
  tool_floor_check nvim
}
: done'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

write_consumer 'called()
{
  tool_floor_check nvim
}
called'
assert_success

write_consumer 'function called {
  tool_floor_check nvim
}
called'
assert_success

# The same defect in the other direction, which is worse than a false pass
# because it refuses correct code: this refactor enforces the floor on every
# path, and the check called it a mention in a comment or a string.
write_consumer 'if ! tool_floor_check nvim; then
  exit 1
fi'
assert_success

write_consumer 'tool_floor_check nvim || exit 1'
assert_success

# Command substitution inside double quotes runs, which is how all four
# platform verifiers read the floor. Blanking quoted text wholesale would
# report every one of them as enforcing nothing.
write_consumer 'check_version_at_least "Neovim" "$(tool_version nvim)" "$(tool_floor nvim)"'
assert_success

# Help text is not a call. The reader used to have no state across lines, so a
# `usage()` heredoc listing the reader's name satisfied the check with no real
# call anywhere, and nearly every script here has that shape (#508, V4-04).
write_consumer 'usage() {
  cat <<'"'"'EOF'"'"'
Usage: enforce.sh
tool_floor_check nvim   check the Neovim floor by hand
EOF
}
usage'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# The subtle spellings of the same thing: a heredoc whose delimiter is bare, a
# string that runs over several lines, and a case arm whose pattern is the
# reader's name. None of them runs the reader.
write_consumer 'cat <<EOF
tool_floor_check nvim
EOF'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

write_consumer 'printf "%s\n" "Checks:
tool_floor_check nvim
done"'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

write_consumer 'case "${1:-}" in
  tool_floor_check) : ;;
esac'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# A subshell body is a definition too, so its floor check does not run on load
# (#508, V4-08)...
write_consumer 'never_called() (
  tool_floor_check nvim
)
: done'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# ...and a comment after a closing brace still closes the function. It used to
# leave the span open to the next closing brace, so the uncalled function below
# was swallowed into the called one and its floor check counted as run.
write_consumer 'called() {
  :
} # called
never_called() {
  tool_floor_check nvim
}
called'
assert_failure
assert_contains "$TEST_OUTPUT" "$unenforced_message"

# A consumer the check cannot parse is unknown, not enforced. An unterminated
# function used to swallow the rest of the file, hiding the real call below it.
write_consumer 'broken() {
  tool_floor_check nvim
: never closed'
assert_failure
assert_contains "$TEST_OUTPUT" 'enforce.sh cannot be read as shell'

# The reader names come from the library, so renaming one is tracked rather
# than leaving this check looking for a name that no longer exists.
renamed="$root/renamed-reader"
mkdir -p "$renamed/common/lib"
sed 's/\btool_floor_check\b/require_tool_floor/g' \
  "$repo_root/common/lib/tool-floors.sh" >"$renamed/common/lib/tool-floors.sh"
run_capture python3 - "$repo_root" "$renamed/common/lib/tool-floors.sh" <<'PY'
import importlib.util, pathlib, sys

repo, library = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "validator", pathlib.Path(repo) / "scripts" / "validate-tool-floors.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(" ".join(sorted(module.readers(pathlib.Path(library)))))
PY
assert_success
assert_contains "$TEST_OUTPUT" 'require_tool_floor tool_floor'
assert_not_contains "$TEST_OUTPUT" 'tool_floor_check'

# tool_version asks a tool its version without comparing it to anything, so it
# is not a reader. Counting it would let a consumer that enforces no floor pass.
run_capture python3 - "$repo_root" "$repo_root/common/lib/tool-floors.sh" <<'PY'
import importlib.util, pathlib, sys

repo, library = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "validator", pathlib.Path(repo) / "scripts" / "validate-tool-floors.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(" ".join(sorted(module.readers(pathlib.Path(library)))))
PY
assert_success
assert_eq 'tool_floor tool_floor_check' "$TEST_OUTPUT" \
  'the readers are the two functions that resolve the registry'

# A library that names no reader leaves every consumer unclassifiable, which
# must fail rather than pass every consumer by default.
mkdir -p "$root/no-reader/common/lib"
printf 'tool_version() {\n  printf 0\n}\n' \
  >"$root/no-reader/common/lib/tool-floors.sh"
run_capture python3 - "$repo_root" "$root/no-reader/common/lib/tool-floors.sh" <<'PY'
import importlib.util, pathlib, sys

repo, library = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "validator", pathlib.Path(repo) / "scripts" / "validate-tool-floors.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    module.readers(pathlib.Path(library))
except module.UnreadableShell as unreadable:
    print(f"refused: {unreadable}")
else:
    print("accepted a library with no reader")
PY
assert_success
assert_contains "$TEST_OUTPUT" 'refused: no function in tool-floors.sh mentions'

# --- The Bash floor, enforced where no reader can run (#539, V5-03) --------
#
# Four entry points decide the Bash floor under whatever Bash started them,
# before the reader library can be sourced, so each compares BASH_VERSINFO
# itself. The validator evaluates each comparison for the version it admits and
# holds it, and every restatement of the number, to the registry row. Before
# the row existed, one site moved to 4.2 left lint green.
bash_fixture="$root/bash-floor"
bash_sites=(common/lib/modern-bash.sh scripts/bootstrap-macos.sh scripts/install-main.sh platforms/macos/install.sh)
mkdir -p "$bash_fixture/config" "$bash_fixture/docs"
for site in "${bash_sites[@]}"; do
  mkdir -p "$bash_fixture/$(dirname "$site")"
  cp "$repo_root/$site" "$bash_fixture/$site"
done
{
  printf 'tool\tmin_version\trequirement\tconsumers\n'
  printf 'bash\t4.4\tEntry points use Bash 4.4 features\t%s\n' "$(IFS=,; printf '%s' "${bash_sites[*]}")"
} >"$bash_fixture/config/tool-floors.tsv"
{
  printf '| Tool | Minimum version | Used by |\n'
  printf '| --- | --- | --- |\n'
  printf '| Bash (`bash`) | >= 4.4 | every entry point |\n'
} >"$bash_fixture/docs/testing.md"
git init -q "$bash_fixture"
git -C "$bash_fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$bash_fixture"
assert_success
printf 'PASS: the four Bash floor sites agree with the registry row\n'

# bash_floor_mutation <site> <sed expression> <expected message>
bash_floor_mutation() {
  local site="$1" expression="$2" expected="$3"
  cp "$repo_root/$site" "$bash_fixture/$site"
  sed -i "$expression" "$bash_fixture/$site"
  if cmp -s "$repo_root/$site" "$bash_fixture/$site"; then
    _test_die "the mutation '$expression' no longer changes $site"
  fi
  run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$bash_fixture"
  cp "$repo_root/$site" "$bash_fixture/$site"
  assert_failure
  assert_contains "$TEST_OUTPUT" "$expected"
}

# The obvious drift, the one the audit made: one refusing test moved to 4.2.
bash_floor_mutation scripts/install-main.sh \
  's/BASH_VERSINFO\[1\] < 4)))/BASH_VERSINFO[1] < 2)))/' \
  'scripts/install-main.sh:5 compares BASH_VERSINFO so that it admits Bash 4.2; tool-floors.tsv says 4.4'

# The subtle one: the number 4 is still written everywhere, but `>=` became
# `>`, so the admitting test now wants 4.5. A check that looked for the
# literal would pass it.
bash_floor_mutation common/lib/modern-bash.sh \
  's/BASH_VERSINFO\[1\] >= 4)))/BASH_VERSINFO[1] > 4)))/' \
  'common/lib/modern-bash.sh:32 compares BASH_VERSINFO so that it admits Bash 4.5'

# The fifth statement, used only for the error message, is held too.
bash_floor_mutation common/lib/modern-bash.sh \
  's/^MODERN_BASH_MINIMUM="4.4"/MODERN_BASH_MINIMUM="4.2"/' \
  'states Bash 4.2 as the minimum in MODERN_BASH_MINIMUM'
printf 'PASS: a Bash floor site that drifts from the row is refused, however it drifts\n'

# A comparison in a file the row does not name is a floor nothing checks. The
# name is composed, because the hygiene gate refuses a tracked file naming a
# repository path that does not exist.
unregistered="scripts/unregistered-floor"
printf '#!/usr/bin/env bash\nif ((BASH_VERSINFO[0] < 5)); then exit 2; fi\n' \
  >"$bash_fixture/$unregistered.sh"
git -C "$bash_fixture" add -A
run_capture python3 "$repo_root/scripts/validate-tool-floors.py" --root "$bash_fixture"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "$unregistered.sh:2 compares BASH_VERSINFO but is not a consumer of the bash row"
git -C "$bash_fixture" rm -q -f "$unregistered.sh"
printf 'PASS: an unregistered BASH_VERSINFO floor is refused\n'

# The runner's own Bash is probed against the row like any other floor.
run_capture "$BASH" -c 'source "$1"; tool_version bash' _ "$repo_root/common/lib/tool-floors.sh"
assert_success
assert_eq "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}" "$TEST_OUTPUT" \
  'tool_version bash reports the interpreter it is asked about'

printf 'Tool version-floor registry, reader and enforcement tests passed.\n'
