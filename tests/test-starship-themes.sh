#!/usr/bin/env bash
# Deterministic Starship generation and the exit-status prompt (issues #125/#169).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

command -v python3 >/dev/null 2>&1 || {
  printf 'python3 is required for the Starship generation tests.\n' >&2
  exit 1
}

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

generator="$repo_root/scripts/update-starship-themes.sh"

# The Fedora validation container ships no diffutils, so this suite compares
# bytes the same dependency-free way the generator does.
files_identical() {
  local first="$1" second="$2" first_content second_content

  [[ -f "$first" && -f "$second" ]] || return 1
  first_content="$(
    cat -- "$first"
    printf end
  )" || return 1
  second_content="$(
    cat -- "$second"
    printf end
  )" || return 1

  [[ "$first_content" == "$second_content" ]]
}
common_source="$repo_root/config/starship/prompt.toml"
palette_dir="$repo_root/config/starship/palettes"
tracked_dir="$repo_root/starship/.config/starship"
flavours=(latte frappe macchiato mocha)

# --- Source ownership (#125) ------------------------------------------------

assert_path_exists "$common_source"
assert_path_missing "$tracked_dir/template.toml"

# The common source must own the shared configuration and nothing flavour
# specific, or the split has not actually happened.
if grep -Eq '^\[palettes\.' "$common_source"; then
  _test_die 'the common prompt source must not define a palette table'
fi
if grep -Eq '^palette[[:space:]]*=' "$common_source"; then
  _test_die 'the common prompt source must not select a palette'
fi

for flavour in "${flavours[@]}"; do
  palette="$palette_dir/catppuccin-${flavour}.toml"
  assert_path_exists "$palette"
  assert_file_line "$palette" "[palettes.catppuccin_${flavour}]"
  assert_eq 1 "$(grep -c '^\[palettes\.' "$palette")" \
    "$palette must define exactly one palette table"
done
printf 'PASS: common prompt and per-flavour palettes are separate sources\n'

# --- Generated invariants (#125) --------------------------------------------

for flavour in "${flavours[@]}"; do
  generated="$tracked_dir/catppuccin-${flavour}.toml"
  assert_path_exists "$generated"
  assert_file_line "$generated" "palette = 'catppuccin_${flavour}'"
  assert_eq 1 "$(grep -c '^\[palettes\.' "$generated")" \
    "$generated must contain exactly one palette table"
  assert_file_line "$generated" "[palettes.catppuccin_${flavour}]"

  for other in "${flavours[@]}"; do
    [[ "$other" != "$flavour" ]] || continue
    assert_file_not_contains "$generated" "[palettes.catppuccin_${other}]"
  done
done
printf 'PASS: each generated flavour carries exactly its own palette\n'

# --- TOML validity and palette references (#125) ----------------------------

python3 - "$tracked_dir" "${flavours[@]}" <<'PYEOF'
import re
import sys
import tomllib
from pathlib import Path

tracked = Path(sys.argv[1])
flavours = sys.argv[2:]

# Style tokens Starship resolves without a palette.
BUILTIN = {
    "bold", "italic", "underline", "dimmed", "inverted", "blink", "strikethrough",
    "hidden", "prev_fg", "prev_bg", "none",
    "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
    "bright-black", "bright-red", "bright-green", "bright-yellow",
    "bright-blue", "bright-purple", "bright-cyan", "bright-white",
}

def colour_tokens(value):
    for token in re.split(r"[\s]+", value):
        token = token.strip()
        if not token:
            continue
        token = token.removeprefix("fg:").removeprefix("bg:")
        # "$style" and friends are Starship variable references resolved at
        # render time, not colour names.
        if not token or token.startswith("#") or token.startswith("$") or token.isdigit():
            continue
        if token in BUILTIN:
            continue
        yield token

def walk(node, sink):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in {"style", "style_user", "style_root"} and isinstance(value, str):
                sink.update(colour_tokens(value))
            elif key == "palettes":
                continue
            else:
                walk(value, sink)
    elif isinstance(node, list):
        for item in node:
            walk(item, sink)
    elif isinstance(node, str):
        # Inline style markup: [text](style)
        for markup in re.findall(r"\]\(([^)]*)\)", node):
            sink.update(colour_tokens(markup))

failures = []
for flavour in flavours:
    path = tracked / f"catppuccin-{flavour}.toml"
    try:
        config = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
        failures.append(f"{path.name}: invalid TOML: {error}")
        continue

    selected = config.get("palette")
    if selected != f"catppuccin_{flavour}":
        failures.append(f"{path.name}: palette is {selected!r}")
        continue
    if not isinstance(selected, str):
        failures.append(f"{path.name}: palette must be a top-level string key")
        continue

    palettes = config.get("palettes", {})
    if set(palettes) != {selected}:
        failures.append(f"{path.name}: palettes are {sorted(palettes)}")
        continue

    defined = set(palettes[selected])
    used = set()
    walk(config, used)
    unknown = sorted(used - defined)
    if unknown:
        failures.append(f"{path.name}: style references no palette entry: {unknown}")

    status = config.get("status", {})
    if status.get("disabled") is not False:
        failures.append(f"{path.name}: [status] must be explicitly enabled")
    if status.get("success_symbol") != "":
        failures.append(f"{path.name}: [status].success_symbol must be empty")
    if status.get("map_symbol") is not False:
        failures.append(f"{path.name}: [status].map_symbol must stay off")
    if "$status" not in status.get("format", ""):
        failures.append(f"{path.name}: [status].format must render $status")
    if "$status" not in config.get("format", ""):
        failures.append(f"{path.name}: prompt format must include $status")
    # TOML folds the "\\"-newline line continuations in the format string, so
    # the parsed value is one run of adjacent module references.
    if "$cmd_duration$status" not in config.get("format", ""):
        failures.append(f"{path.name}: $status must directly follow $cmd_duration")
    if "$status$line_break" not in config.get("format", ""):
        failures.append(f"{path.name}: $status must directly precede the line break")
    character = config.get("character", {})
    if "fg:red" not in character.get("error_symbol", ""):
        failures.append(f"{path.name}: the red error prompt character must remain")

if failures:
    for failure in failures:
        print(f"TEST FAILURE: {failure}", file=sys.stderr)
    raise SystemExit(1)
PYEOF
printf 'PASS: every generated flavour is valid TOML with resolvable colours\n'

# --- Determinism and the drift gate (#125 addendum) -------------------------

# The generator must never need to touch the working tree to be checked, so
# everything below runs against a disposable copy of the three source trees.
fake_root="$root/fake-repo"
mkdir -p "$fake_root/scripts" "$fake_root/config" "$fake_root/starship/.config"
cp "$generator" "$fake_root/scripts/update-starship-themes.sh"
cp -r "$repo_root/config/starship" "$fake_root/config/starship"
cp -r "$tracked_dir" "$fake_root/starship/.config/starship"
fake_generator="$fake_root/scripts/update-starship-themes.sh"

run_capture "$fake_generator" --check
assert_success
assert_contains "$TEST_OUTPUT" 'are current'

# Generating into a temporary output root must reproduce the tracked bytes.
generated_dir="$root/generated"
run_capture "$generator" --output-dir "$generated_dir"
assert_success
for flavour in "${flavours[@]}"; do
  files_identical "$generated_dir/catppuccin-${flavour}.toml" \
    "$tracked_dir/catppuccin-${flavour}.toml" ||
    _test_die "tracked catppuccin-${flavour}.toml is stale; run ./scripts/update-starship-themes.sh"
done

# Running generation twice must produce byte-identical files.
second_dir="$root/generated-again"
run_capture "$generator" --output-dir "$second_dir"
assert_success
for flavour in "${flavours[@]}"; do
  files_identical "$generated_dir/catppuccin-${flavour}.toml" \
    "$second_dir/catppuccin-${flavour}.toml" ||
    _test_die "generation is not idempotent for $flavour"
done
printf 'PASS: generation is deterministic and the tracked files are current\n'

# A source change without regenerated outputs must fail, name the stale files,
# and leave the checkout untouched.
before="$(cat "$fake_root/starship/.config/starship/catppuccin-mocha.toml")"
printf '\n[hostname]\ndisabled = true\n' >>"$fake_root/config/starship/prompt.toml"
run_capture "$fake_generator" --check
assert_failure
assert_contains "$TEST_OUTPUT" 'are stale'
for flavour in "${flavours[@]}"; do
  assert_contains "$TEST_OUTPUT" "catppuccin-${flavour}.toml"
done
assert_eq "$before" "$(cat "$fake_root/starship/.config/starship/catppuccin-mocha.toml")" \
  '--check must not modify the working tree'

run_capture "$fake_generator"
assert_success
run_capture "$fake_generator" --check
assert_success
printf 'PASS: a stale generated file fails the drift gate without being fixed\n'

# A palette change alone must also be caught.
cp -r "$repo_root/config/starship" "$fake_root/config/starship.reset"
rm -rf "$fake_root/config/starship"
mv "$fake_root/config/starship.reset" "$fake_root/config/starship"
cp "$tracked_dir"/catppuccin-*.toml "$fake_root/starship/.config/starship/"
run_capture "$fake_generator" --check
assert_success
printf 'red = "#000000"\n' >>"$fake_root/config/starship/palettes/catppuccin-mocha.toml"
run_capture "$fake_generator" --check
assert_failure
assert_contains "$TEST_OUTPUT" 'catppuccin-mocha.toml'
assert_not_contains "$TEST_OUTPUT" 'catppuccin-latte.toml'
printf 'PASS: a palette-only source change is detected per flavour\n'

# The generator refuses sources that would defeat the one-palette invariant.
cp -r "$repo_root/config/starship" "$root/broken-config"
printf "\npalette = 'catppuccin_mocha'\n" >>"$root/broken-config/prompt.toml"
broken_root="$root/broken-repo"
mkdir -p "$broken_root/scripts" "$broken_root/config"
cp "$generator" "$broken_root/scripts/update-starship-themes.sh"
cp -r "$root/broken-config" "$broken_root/config/starship"
run_capture "$broken_root/scripts/update-starship-themes.sh" --output-dir "$root/broken-out"
assert_failure
assert_contains "$TEST_OUTPUT" 'must not select a palette'

rm -rf "$broken_root/config/starship"
cp -r "$repo_root/config/starship" "$broken_root/config/starship"
rm "$broken_root/config/starship/palettes/catppuccin-frappe.toml"
run_capture "$broken_root/scripts/update-starship-themes.sh" --output-dir "$root/broken-out"
assert_failure
assert_contains "$TEST_OUTPUT" 'palette source not found'
printf 'PASS: the generator fails closed on unusable sources\n'

# --- Runtime selection contract (unchanged by #125) -------------------------

# shellcheck disable=SC2016 # Matching the literal text in .zshrc.
assert_file_contains "$repo_root/zsh/.config/zsh/.zshrc" \
  'starship/catppuccin-${DOTFILES_THEME}.toml'
printf 'PASS: the STARSHIP_CONFIG selection contract is unchanged\n'

# --- Exit status rendering (#169) -------------------------------------------

if command -v starship >/dev/null 2>&1; then
  # Render from outside any Git working tree: the git_status module uses the
  # same ✘ glyph for a deleted file, which would make the success assertion
  # below pass or fail for the wrong reason.
  render() {
    local config="$1" status_code="$2"
    (
      cd "$root/home" || exit 1
      STARSHIP_CONFIG="$config" HOME="$root/home" \
        starship prompt --status "$status_code" --cmd-duration 2000 \
        2>"$root/starship.err"
    )
  }

  for flavour in "${flavours[@]}"; do
    config="$tracked_dir/catppuccin-${flavour}.toml"

    success_prompt="$(render "$config" 0)"
    [[ -s "$root/starship.err" ]] &&
      _test_die "starship reported a configuration problem for $flavour: $(cat "$root/starship.err")"
    assert_not_contains "$success_prompt" '✘'
    assert_contains "$success_prompt" 'in 2s'

    for status_code in 1 2 126 127 130; do
      failure_prompt="$(render "$config" "$status_code")"
      assert_contains "$failure_prompt" "✘ $status_code"
      assert_contains "$failure_prompt" 'in 2s'
    done

    # Layout stays clean when the duration segment is absent too.
    quick="$(cd "$root/home" && STARSHIP_CONFIG="$config" HOME="$root/home" \
      starship prompt --status 127)"
    assert_contains "$quick" '✘ 127'
  done

  # Each flavour must colour the status with its own palette's red.
  latte_red="$(render "$tracked_dir/catppuccin-latte.toml" 7)"
  mocha_red="$(render "$tracked_dir/catppuccin-mocha.toml" 7)"
  assert_contains "$latte_red" '38;2;210;15;57'
  assert_contains "$mocha_red" '38;2;243;139;168'
  printf 'PASS: starship renders the exact exit code only after failures\n'
else
  printf 'SKIP: starship is not installed; rendering assertions were not run\n'
fi

printf 'Starship generation and exit-status prompt tests passed.\n'
