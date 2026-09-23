#!/usr/bin/env bash
# Canonical custom-action registry, full reference, and printable sheets (#160).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

registry="$repo_root/config/actions.tsv"
reference="$repo_root/docs/reference/keybindings.md"
validator="$repo_root/scripts/validate-actions.py"
renderer="$repo_root/scripts/render-action-reference.py"

# field <id> <column>: one registry cell, read the way the validator reads it.
field() {
  python3 - "$registry" "$1" "$2" <<'PYTHON'
import csv, sys
registry, wanted, column = sys.argv[1:4]
with open(registry, newline="", encoding="utf-8") as stream:
    for row in csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
        if row["id"] == wanted:
            print(row[column])
            break
PYTHON
}

# with_registry <python-snippet>: run the validator against a copy of the real
# registry that the snippet has mutated, so each negative case differs from the
# passing state in exactly one way.
with_registry() {
  local snippet="$1"
  test_new_root
  local scratch="$TEST_ROOT/tree"
  mkdir -p "$scratch"
  cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
    "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
    "$scratch/"
  python3 - "$scratch/config/actions.tsv" <<PYTHON
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
header = lines[0].split("\t")
rows = [dict(zip(header, line.split("\t"))) for line in lines[1:]]
by_id = {row["id"]: row for row in rows}
$snippet
path.write_text(
    "\t".join(header) + "\n"
    + "\n".join("\t".join(row[column] for column in header) for row in rows) + "\n",
    encoding="utf-8")
PYTHON
  run_capture python3 "$validator" --root "$scratch"
}

# --- The repository satisfies its own registry ------------------------------

run_capture python3 "$validator"
assert_success
printf 'PASS: the tracked registry matches the tracked configuration and sheets\n'

run_capture python3 "$renderer" --check
assert_success
printf 'PASS: the generated action reference is current\n'

# --- Every registered action reaches the full reference ---------------------

# The generated table escapes a pipe inside a cell, so compare the escaped
# form rather than the raw registry value.
escaped_binding() {
  printf '%s' "${1//|/\\|}"
}

missing=0
while IFS=$'\t' read -r id binding; do
  [[ "$id" != "id" ]] || continue
  grep -Fq -- "$(escaped_binding "$binding")" "$reference" || {
    printf 'FAIL: %s (%s) is registered but absent from the full reference\n' \
      "$id" "$binding" >&2
    missing=$((missing + 1))
  }
done < <(cut -f 1,7 "$registry")
((missing == 0)) || _test_die "$missing registered action(s) missing from the full reference"
printf 'PASS: every registered action appears in the full reference\n'

# --- print=false actions stay in the reference and off every sheet ----------

# printed_by_another <binding> <sheet>: true when some *other* registry row
# with the same binding legitimately prints it on that sheet. x-copy exists on
# both the Fedora VM guest (not printed) and the Parrot guest (printed), and
# the same key text on two platforms is not the same action.
printed_by_another() {
  awk -F '\t' -v want="$1" -v sheet="$2" \
    'NR > 1 && $7 == want && $12 == "true" {
       claims = $13
       gsub(/:prose/, "", claims)
       if (index("," claims ",", "," sheet ",")) found = 1
     }
     END { exit !found }' "$registry"
}

excluded=0
while IFS=$'\t' read -r id binding print; do
  [[ "$print" == "false" ]] || continue
  grep -Fq -- "$(escaped_binding "$binding")" "$reference" ||
    _test_die "$id is print=false but missing from the full reference"
  for sheet in "$repo_root"/docs/cheatsheets/*.tex; do
    sheet_name="${sheet##*/}"
    sheet_name="${sheet_name%.tex}"
    if grep -Fq -- "\\csrow{$binding}" "$sheet"; then
      printed_by_another "$binding" "$sheet_name" ||
        _test_die "$id is print=false but printed on ${sheet##*/}"
    fi
  done
  excluded=$((excluded + 1))
done < <(cut -f 1,7,12 "$registry")
((excluded > 0)) || _test_die "the registry has no print=false actions to check"
printf 'PASS: %d print=false actions stay in the full reference and off every sheet\n' "$excluded"

# --- A renamed binding in the tracked config is caught ----------------------

test_new_root
scratch="$TEST_ROOT/renamed"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
# shellcheck disable=SC2016 # $mod is a literal Sway variable.
sed -i 's/bindsym \$mod+Return exec ghostty/bindsym $mod+Escape exec ghostty/' \
  "$scratch/platforms/fedora/stow/sway/.config/sway/config"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "sway.launch.terminal: source_pattern no longer matches"
printf 'PASS: renaming a binding without updating the registry fails\n'

# --- A commented-out binding in the tracked config is caught ----------------

# A `#` line is read by nobody, so a source_pattern that lands on one is no
# evidence the action exists; the registry and the printed sheet would keep
# advertising a key that does nothing. `implemented_actions` already reads the
# Sway config line by line, and this is the same rule for the other direction.
test_new_root
scratch="$TEST_ROOT/commented-sway"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
# shellcheck disable=SC2016 # $mod is a literal Sway variable.
sed -i 's|^bindsym \$mod+Return exec ghostty|# bindsym $mod+Return exec ghostty|' \
  "$scratch/platforms/fedora/stow/sway/.config/sway/config"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "sway.launch.terminal: source_pattern no longer matches"
printf 'PASS: commenting a Sway binding out without updating the registry fails\n'

# The same rule with Lua comment syntax, so the per-suffix comment prefix is
# exercised rather than assumed.
test_new_root
scratch="$TEST_ROOT/commented-lua"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
sed -i 's|^\( *\)lhs = "<leader>tr"|\1-- lhs = "<leader>tr"|' \
  "$scratch/nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "nvim.dotnet.run-nearest: source_pattern no longer matches"
printf 'PASS: commenting a Neovim keymap out without updating the registry fails\n'

# A block comment disables just as completely, and Neovim really does stop
# loading the keys inside one: this check knew only line prefixes, so two
# keymaps could be wrapped in `--[[ ]]` while the registry and the printed
# sheets kept advertising them.
test_new_root
scratch="$TEST_ROOT/block-commented-lua"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
python3 - "$scratch/nvim-lazyvim/.config/nvim/lua/plugins/latex.lua" <<'PYTHON'
import pathlib
import sys

spec = pathlib.Path(sys.argv[1])
text = spec.read_text(encoding="utf-8")
wrapped = (
    '      { "<localleader>le", "<plug>(vimtex-errors)", desc = "Build errors", '
    'ft = "tex" },'
)
if wrapped not in text:
    raise SystemExit("the keymap this case comments out is gone")
spec.write_text(text.replace(wrapped, f"      --[[\n{wrapped}\n      ]]", 1), encoding="utf-8")
PYTHON
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "nvim.latex.errors: source_pattern no longer matches"
printf 'PASS: a keymap disabled with a Lua block comment fails the registry\n'

# The same in JSONC, where the two directions of this check used to disagree:
# the reader that parses Waybar's configuration saw a `/* */` binding as gone
# while the reader that matches source_pattern still saw it as present.
test_new_root
scratch="$TEST_ROOT/block-commented-jsonc"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
python3 - "$scratch/platforms/fedora/stow/waybar/.config/waybar/config.jsonc" <<'PYTHON'
import pathlib
import sys

config = pathlib.Path(sys.argv[1])
text = config.read_text(encoding="utf-8")
binding = '    "on-click": "blueman-manager"'
if binding not in text:
    raise SystemExit("the Waybar click this case comments out is gone")
config.write_text(
    text.replace(binding, f'    /* {binding.strip()} */ "tooltip": true', 1),
    encoding="utf-8",
)
PYTHON
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "waybar.bluetooth.click: source_pattern no longer matches"
printf 'PASS: a Waybar click disabled with a JSONC block comment fails the registry\n'

# --- An unregistered custom action is caught --------------------------------

test_new_root
scratch="$TEST_ROOT/unregistered"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
# shellcheck disable=SC2016 # $mod is a literal Sway variable.
printf 'bindsym $mod+Shift+Y exec never-registered\n' \
  >>"$scratch/platforms/fedora/stow/sway/.config/sway/config"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "unregistered custom action"
printf 'PASS: an unregistered Sway binding fails\n'

test_new_root
scratch="$TEST_ROOT/unregistered-alias"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
printf "\nalias never-registered='true'\n" >>"$scratch/zsh/.config/zsh/.zshrc"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "unregistered custom action"
printf 'PASS: an unregistered shell alias fails\n'

test_new_root
scratch="$TEST_ROOT/unregistered-aerospace"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
python3 - "$scratch/platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml" <<'PYTHON'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("[mode.main.binding]", "[mode.main.binding]\nctrl-alt-y = 'close-all-windows-but-current'", 1)
path.write_text(text, encoding="utf-8")
PYTHON
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "unregistered custom action"
printf 'PASS: an unregistered AeroSpace binding fails, through a real TOML parse\n'

test_new_root
scratch="$TEST_ROOT/unregistered-waybar"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
python3 - "$scratch/platforms/fedora/stow/waybar/.config/waybar/config.jsonc" <<'PYTHON'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace('"on-click": "pavucontrol"', '"on-click": "pavucontrol",\n    "on-scroll-up": "never-registered"', 1)
path.write_text(text, encoding="utf-8")
PYTHON
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "unregistered custom action"
printf 'PASS: an unregistered Waybar click fails, through a real JSON parse\n'

# --- Schema rules -----------------------------------------------------------

with_registry 'by_id["sway.launch.terminal"]["print_reason"] = "-"
by_id["sway.launch.terminal"]["print"] = "false"
by_id["sway.launch.terminal"]["sheets"] = "-"'
assert_failure
assert_contains "$TEST_OUTPUT" "print=false requires a rationale"
printf 'PASS: excluding an action from the sheets without a reason fails\n'

with_registry 'by_id["sway.launch.launcher"]["sheets"] = "fedora-kde"'
assert_failure
assert_contains "$TEST_OUTPUT" "the sheet does not document"
printf 'PASS: claiming a sheet that does not print the action fails\n'

with_registry 'rows.append(dict(by_id["sway.launch.terminal"]))'
assert_failure
assert_contains "$TEST_OUTPUT" "duplicate action id"
printf 'PASS: a duplicate action id fails\n'

with_registry 'by_id["sway.window.kill"]["print"] = "false"
by_id["sway.window.kill"]["sheets"] = "-"
by_id["sway.window.kill"]["print_reason"] = "deliberately untested"'
assert_failure
assert_contains "$TEST_OUTPUT" "is not in config/actions.tsv for this sheet"
printf 'PASS: a sheet that prints an unregistered action fails\n'

with_registry 'by_id["nvim.markdown.insert-table"]["profile"] = "spreadsheets"'
assert_failure
assert_contains "$TEST_OUTPUT" "invalid profile 'spreadsheets'"
printf 'PASS: a profile that names no capability in config/capabilities.tsv fails\n'

with_registry 'by_id["zsh.alias.eza"]["platform"] = "amiga"'
assert_failure
assert_contains "$TEST_OUTPUT" "invalid platform 'amiga'"
printf 'PASS: a platform outside config/capabilities.tsv fails\n'

# --- A sheet omission has to be a decision ----------------------------------

with_registry 'by_id["zsh.alias.tree"]["sheets"] = "fedora-kde,fedora-sway,fedora-wsl,macos"'
assert_failure
assert_contains "$TEST_OUTPUT" "exists on parrot-ctf but is not printed there"
printf 'PASS: dropping a sheet an action reaches, with no reason, fails\n'

# The tracked registry withholds the LazyVim keymap from the Parrot sheet and
# says why; erasing that sentence is what the rule is there to catch.
with_registry 'by_id["lazyvim.find-files"]["print_reason"] = "-"'
assert_failure
assert_contains "$TEST_OUTPUT" "exists on parrot-ctf but is not printed there"
printf 'PASS: erasing the reason for a recorded omission fails\n'

# A workstation-only action does not reach the CTF guest's sheet at all, so it
# owes no reason for being absent from it.
[[ "$(field nvim.latex.compile platform)" == workstation ]] ||
  _test_die "the workstation-only Neovim actions must not claim platform=all"

# --- A prose claim is deliberate on both sides ------------------------------

with_registry 'by_id["lazyvim.whichkey"]["sheets"] = "fedora-kde,fedora-sway,fedora-wsl,macos,parrot-ctf"'
assert_failure
assert_contains "$TEST_OUTPUT" "the sheet does not document"
printf 'PASS: a prose-only claim written as a table claim fails\n'

with_registry 'by_id["zsh.alias.bat"]["sheets"] = "fedora-kde:prose,fedora-sway,fedora-wsl,macos,parrot-ctf"'
assert_failure
assert_contains "$TEST_OUTPUT" "carries no '% csprose: zsh.alias.bat' marker"
printf 'PASS: claiming prose a sheet never marked fails\n'

# --- A sheet may not keep the key and change what it says the key does ------

test_new_root
scratch="$TEST_ROOT/redescribed"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
sed -i 's/\\csrow{Super+Enter}{Open Ghostty}/\\csrow{Super+Enter}{Raise the volume}/' \
  "$scratch/docs/cheatsheets/fedora-sway.tex"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "shares no word with the registry's"
printf 'PASS: a sheet description that no longer matches the registry fails\n'

# --- An interpreter line is not evidence that an action still exists --------

with_registry 'by_id["parrot.verify"]["source_pattern"] = "#!/usr/bin/env bash"'
assert_failure
assert_contains "$TEST_OUTPUT" "only matches the shebang"
printf 'PASS: a source pattern that only matches a shebang fails\n'

# --- The widened extraction sees the rest of the tracked configuration ------

for case in \
  "tmux/.tmux.conf:set -g prefix C-a" \
  "zsh/.config/zsh/.zshrc:setopt AUTO_PUSHD"; do
  file="${case%%:*}"
  line="${case#*:}"
  test_new_root
  scratch="$TEST_ROOT/extraction"
  mkdir -p "$scratch"
  cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
    "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
    "$scratch/"
  printf '\n%s\n' "$line" >>"$scratch/$file"
  run_capture python3 "$validator" --root "$scratch"
  assert_failure
  assert_contains "$TEST_OUTPUT" "unregistered custom action"
  printf 'PASS: an unregistered action in %s fails\n' "$file"
done

test_new_root
scratch="$TEST_ROOT/unregistered-command"
mkdir -p "$scratch"
cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
  "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
  "$scratch/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$scratch/bin/.local/bin/never-registered"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "never-registered on PATH"
printf 'PASS: an unregistered command on PATH fails\n'

# --- The agent permission bypass is an explicit safety decision (#503) -----

# bypass_tree <name>: a fresh copy of everything the validator reads, in
# $scratch, for one mutation of the permission-bypass alias.
bypass_tree() {
  test_new_root
  scratch="$TEST_ROOT/$1"
  mkdir -p "$scratch"
  cp -r "$repo_root/config" "$repo_root/docs" "$repo_root/platforms" \
    "$repo_root/zsh" "$repo_root/nvim-lazyvim" "$repo_root/bin" "$repo_root/tmux" \
    "$scratch/"
}

bypass_alias="alias claude-unsafe='claude --dangerously-skip-permissions'"
grep -Fq -- "$bypass_alias" "$repo_root/zsh/.config/zsh/.zshrc" ||
  _test_die "the tracked .zshrc no longer defines: $bypass_alias"

# The registry used to pin only the prefix `alias cld='claude`, so any flag
# appended to the alias rode along with exit 0 while every sheet kept calling
# it "permission prompts disabled".
bypass_tree bypass-appended
sed -i "s|$bypass_alias|${bypass_alias%\'} --mcp-config /tmp/evil.json'|" \
  "$scratch/zsh/.config/zsh/.zshrc"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "zsh.alias.claude-unsafe: source_pattern no longer matches"
printf 'PASS: a flag appended to the permission-bypass alias fails\n'

# A registry row that goes back to pinning a prefix is refused by itself,
# before anything has drifted underneath it.
with_registry "by_id['zsh.alias.claude-unsafe']['source_pattern'] = \"alias claude-unsafe='claude\""
assert_failure
assert_contains "$TEST_OUTPUT" "must match the whole permission-bypass alias"
printf 'PASS: a registry row pinning only a prefix of the bypass alias fails\n'

# Renamed back to a short name, with the registry and sheet following it so
# that only the naming rule is left to object.
bypass_tree bypass-short-name
sed -i "s|alias claude-unsafe=|alias cld=|" "$scratch/zsh/.config/zsh/.zshrc"
sed -i 's|\\csrow{claude-unsafe}|\\csrow{cld}|' "$scratch/docs/cheatsheets/common-workflow.tex"
python3 - "$scratch/config/actions.tsv" <<'PYTHON'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("\tclaude-unsafe\t", "\tcld\t").replace("alias claude-unsafe=", "alias cld=")
path.write_text(text, encoding="utf-8")
PYTHON
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "the permission-bypass alias 'cld' must say 'unsafe' in its name"
printf 'PASS: a permission-bypass alias without "unsafe" in its name fails\n'

# A wrapper function has a body the registry cannot pin.
bypass_tree bypass-function
printf 'cld() {\n  claude --dangerously-skip-permissions "$@"\n}\n' \
  >>"$scratch/zsh/.config/zsh/.zshrc"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "may only be defined as a shell alias"
printf 'PASS: a permission-bypass wrapper function fails\n'

# Nor may a command on PATH carry the flag, whatever it is called. Codex's own
# spelling of the same bypass is held to the same rule.
bypass_tree bypass-command
printf '#!/usr/bin/env bash\nexec codex --dangerously-bypass-approvals-and-sandbox "$@"\n' \
  >"$scratch/bin/.local/bin/codex-unsafe"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "bin/.local/bin/codex-unsafe:2: an agent permission bypass may only be defined as a shell alias"
printf 'PASS: a command on PATH carrying a permission bypass fails\n'

# The warning has to travel with the name: registry and every printed sheet.
with_registry "by_id['zsh.alias.claude-unsafe']['action'] = 'Claude Code, started with permission prompts disabled'"
assert_failure
assert_contains "$TEST_OUTPUT" "zsh.alias.claude-unsafe: the action must warn that 'claude-unsafe' is 'unsafe'"
printf 'PASS: a registry description without the unsafe warning fails\n'

bypass_tree bypass-sheet
sed -i 's|\\csrow{claude-unsafe}{[^}]*}|\\csrow{claude-unsafe}{Claude Code, all permission prompts off}|' \
  "$scratch/docs/cheatsheets/common-workflow.tex"
run_capture python3 "$validator" --root "$scratch"
assert_failure
assert_contains "$TEST_OUTPUT" "docs/cheatsheets/macos.tex must warn that 'claude-unsafe' is 'unsafe'"
printf 'PASS: a printed sheet without the unsafe warning fails\n'

# --- Platform-accurate sheets ----------------------------------------------

# A shared block must not become platform-inaccurate. The expanded sheet is
# what a user prints, so the check reads the sheet with its \input resolved.
expand_sheet() {
  python3 - "$repo_root/docs/cheatsheets" "$1" <<'PYTHON'
import pathlib, re, sys
directory, sheet = pathlib.Path(sys.argv[1]), sys.argv[2]
text = (directory / f"{sheet}.tex").read_text(encoding="utf-8")
for match in re.finditer(r"\\input\{([^}]+)\}", text):
    included = directory / f"{match.group(1)}.tex"
    if included.is_file():
        text += "\n" + included.read_text(encoding="utf-8")
print(text)
PYTHON
}

# Each entry names a concrete command, flag or component a user could try to
# use on that sheet's platform and fail with. Cross-references in prose ("the
# same grid as Sway") are fine and deliberately not matched.
for sheet_platform in \
  "fedora-wsl:--preserve-wallpaper" "fedora-wsl:swaymsg" "fedora-wsl:Fuzzel" \
  "fedora-wsl:swaylock" "fedora-wsl:ghostty +list-keybinds" \
  "macos:swaymsg" "macos:Fuzzel" "macos:makoctl" \
  "parrot-ctf:Ghostty" "parrot-ctf:AeroSpace" "parrot-ctf:Waybar" \
  "parrot-ctf:--preserve-wallpaper"; do
  sheet_name="${sheet_platform%%:*}"
  forbidden="${sheet_platform#*:}"
  sheet_text="$(expand_sheet "$sheet_name")"
  if grep -Fqi -- "$forbidden" <<<"$sheet_text"; then
    _test_die "$sheet_name.tex must not advertise '$forbidden'"
  fi
done

# The WSL sheet must name the terminal Windows actually runs.
#
# Expanded into a variable first, deliberately. Piping into `grep -Fq` makes
# grep exit at the first match, and the Python expander is still writing: it
# takes SIGPIPE, and `pipefail` turns that into a failed pipeline, so the
# assertion fails exactly when the text it is looking for IS present. Seen
# once on a loaded machine. Every assertion that expects a match has to read
# its producer to the end.
wsl_sheet_text="$(expand_sheet fedora-wsl)"
grep -Fq 'Noctty' <<<"$wsl_sheet_text" ||
  _test_die 'fedora-wsl.tex must name Noctty as the Windows-side terminal'
printf 'PASS: no sheet advertises a component its platform does not have\n'

# The reduced guest gets a real, deliberately small operations reference.
assert_file_contains "$repo_root/docs/cheatsheets/parrot-ctf.tex" 'hex-encode'
assert_file_contains "$repo_root/docs/cheatsheets/parrot-ctf.tex" 'x-copy'
printf 'PASS: the reduced Parrot guest has its own operations sheet\n'

# --- Page budgets are declared for every sheet ------------------------------

# A sheet is a .tex with its own \documentclass; the rest (common-workflow,
# ghostty-linux-keys) are fragments other sheets \input, and a fragment has no
# page count of its own to budget.
for sheet in "$repo_root"/docs/cheatsheets/*.tex; do
  name="${sheet##*/}"
  name="${name%.tex}"
  grep -Fq '\documentclass' "$sheet" || continue
  grep -Eq "^  \[$name\]=[0-9]+$" "$repo_root/docs/cheatsheets/verify.sh" ||
    _test_die "docs/cheatsheets/verify.sh declares no page budget for $name"
done
printf 'PASS: every printable sheet has a declared page budget\n'

# --- The registry stays the single normative source -------------------------

assert_file_contains "$reference" "BEGIN GENERATED ACTION REFERENCE"
assert_file_contains "$reference" "Complete action reference"
[[ "$(field sway.launch.terminal origin)" == repository ]] ||
  _test_die "a Sway binding must be recorded as repository-defined"
[[ "$(field lazyvim.whichkey origin)" == upstream ]] ||
  _test_die "an upstream LazyVim binding must be recorded as upstream"
printf 'PASS: repository-defined and upstream actions stay distinguishable\n'

printf '\nAll action registry checks passed.\n'
