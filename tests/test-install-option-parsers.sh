#!/usr/bin/env bash
# The platform installers' argv parsers against config/install-options.tsv
# (#242). Neither may gain a flag the other does not know: a parser-only flag
# is never remembered by --rerun, and a manifest-only flag stops every install
# on its platform.
#
# Each negative case edits a scratch copy of the repository and runs that
# copy's validator, or points the validator at a scratch manifest through
# INSTALL_OPTION_MANIFEST. This checkout is never modified.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# scratch_tree: a disposable copy of this checkout, without its Git metadata.
scratch_tree() {
  test_new_root
  tree="$TEST_ROOT/tree"
  mkdir -p "$tree"
  cp -R "$repo_root/." "$tree/"
  rm -rf -- "$tree/.git"
}

# replace_line FILE OLD NEW: replace one exact line. A line that is not there
# exactly once fails the suite, so a reworded installer cannot turn a negative
# case into a vacuous pass.
replace_line() {
  python3 - "$@" <<'PYTHON'
import pathlib
import sys

path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text(encoding="utf-8").split("\n")
if lines.count(old) != 1:
    sys.exit(f"expected exactly one line {old!r} in {path}")
lines[lines.index(old)] = new
path.write_text("\n".join(lines), encoding="utf-8")
PYTHON
}

fedora_kde_arm='  --kde) install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;'
fedora_tailscale_arm='  --tailscale) install_tailscale=true; shift ;; --no-tailscale) install_tailscale=false; shift ;;'
wsl_tailscale_arm="  --tailscale | --no-tailscale) die '--tailscale is not supported on Fedora WSL: install Tailscale on the Windows host instead.' ;;"

run_capture python3 "$repo_root/scripts/validate-install-options.py"
assert_success
printf 'PASS: every installer parser agrees with the option manifest\n'

# --- A flag the parser accepts but the manifest never declares ---------------

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "$fedora_kde_arm
  --turbo) install_turbo=true; shift ;; --no-turbo) install_turbo=false; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: platforms/fedora/install.sh accepts --turbo, which the manifest does not declare"
assert_contains "$TEST_OUTPUT" "accepts --no-turbo"
printf 'PASS: a parser flag missing from the manifest fails, by name\n'

# --- A manifest option the parser never implements ---------------------------

test_new_root
manifest="$TEST_ROOT/install-options.tsv"
cp "$repo_root/config/install-options.tsv" "$manifest"
printf 'fedora\tfooopt\tboolean\t--fooopt\t--no-fooopt\tfalse\t-\t-\tFoo option\n' >>"$manifest"
run_capture env "INSTALL_OPTION_MANIFEST=$manifest" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --fooopt, but platforms/fedora/install.sh has no case arm for it"
assert_contains "$TEST_OUTPUT" "declares --no-fooopt"
printf 'PASS: a manifest option the parser does not implement fails, by name\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_tailscale_arm" \
  '  --no-tailscale) install_tailscale=false; shift ;;'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --tailscale, but platforms/fedora/install.sh has no case arm for it"
assert_not_contains "$TEST_OUTPUT" "--no-tailscale"
printf 'PASS: a deleted parser arm fails, naming only the flag that lost it\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde) die 'no KDE today' ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest declares --kde, but platforms/fedora/install.sh rejects it"
printf 'PASS: a manifest option the parser rejects fails, by name\n'

# --- Deliberate rejections stay deliberate -----------------------------------

scratch_tree
replace_line "$tree/platforms/fedora-wsl/install.sh" "$wsl_tailscale_arm" ''
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora-wsl: --tailscale is listed in REJECTED_FLAGS, but platforms/fedora-wsl/install.sh has no case arm that rejects it"
printf 'PASS: a documented rejection whose arm disappeared fails, by name\n'

scratch_tree
replace_line "$tree/platforms/fedora-wsl/install.sh" "$wsl_tailscale_arm" \
  '  --tailscale | --no-tailscale) shift ;;'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora-wsl: --tailscale is listed in REJECTED_FLAGS, but platforms/fedora-wsl/install.sh accepts it"
printf 'PASS: a rejected flag the parser starts accepting fails, by name\n'

scratch_tree
replace_line "$tree/platforms/macos/install.sh" \
  '  --non-interactive) interactive=false; shift ;;' \
  "  --non-interactive) interactive=false; shift ;;
  --sway | --no-sway) die 'Sway is a Linux session.' ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "macos: platforms/macos/install.sh rejects --sway; list it in REJECTED_FLAGS with the reason"
printf 'PASS: an undocumented rejection fails, by name\n'

# --- Arm shapes the reader used to walk straight past ------------------------

# A glob arm is how a parser accepts `--jobs=4` in one word. `=` is not a word
# character, so the pattern half of the old arm regex never lined up with this
# arm's `)`: the flag was accepted by the installer and invisible here, which
# is a flag `./install.sh --rerun` can never remember.
scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "$fedora_kde_arm
  --jobs=*) install_jobs=\"\${1#--jobs=}\"; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: platforms/fedora/install.sh accepts --jobs=*, which the manifest does not declare"
printf 'PASS: a glob arm is read, so the flag it accepts is compared\n'

# `;&` falls through to the next arm instead of leaving the case. Reading only
# `;;` as a terminator let the first body run past it and swallow the pattern
# of the arm below, so that arm's flags were never seen at all.
scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde) install_kde=enabled ;& --turbo) install_turbo=true; shift ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: platforms/fedora/install.sh accepts --turbo, which the manifest does not declare"
printf 'PASS: an arm after a `;&` fallthrough is read like any other\n'

# An arm can match its flag and record nothing: the install runs with KDE
# selected and the machine remembers no such selection.
scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde) shift ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: platforms/fedora/install.sh accepts --kde and only shifts past it"
printf 'PASS: an arm that accepts a persistent flag and only shifts fails\n'

# A rejection is `die`, not a word that starts with it. `die_if_wsl` is a check
# an arm runs before accepting the flag, and reading it as a refusal reported a
# supported flag as rejected on the platform that takes it.
scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde) die_if_wsl; install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_success
printf 'PASS: an arm that runs a `die_`-prefixed check still accepts its flag\n'

# An arm shape the reader cannot parse is unknown, not absent: skipping it
# takes the flag out of the comparison in both directions at once.
scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_kde_arm" \
  "  --kde|--kde-\$(hostname)) install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" "an argv arm could not be parsed"
printf 'PASS: an argv arm the reader cannot parse is a build error\n'

# --- The declared default is the installer's own default --------------------

# The manifest and the generated reference both publish this column as fact,
# and nothing compared it with the value the installer starts from: flipping
# the macOS `defaults` row passed every validator, every render gate and every
# suite while the installer went on defaulting it to true.
test_new_root
manifest="$TEST_ROOT/drifted-default.tsv"
python3 - "$repo_root/config/install-options.tsv" "$manifest" <<'PYTHON'
import pathlib
import sys

source, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = source.read_text(encoding="utf-8").splitlines()
for number, line in enumerate(lines):
    fields = line.split("\t")
    if fields[:2] == ["macos", "defaults"]:
        fields[5] = "false"
        lines[number] = "\t".join(fields)
        break
else:
    raise SystemExit("the macos defaults row this case flips is gone")
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
run_capture env "INSTALL_OPTION_MANIFEST=$manifest" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "macos: the manifest gives defaults the default 'false', but platforms/macos/install.sh starts with apply_defaults='true'"
printf 'PASS: a declared default the installer contradicts fails, by name\n'

# The same check from the other side, and through the one indirection the
# installers use: the flavour default is stated once in a shared library and
# assigned from there by all four.
scratch_tree
replace_line "$tree/common/lib/theme-selection.sh" 'THEME_DEFAULT_FLAVOUR=macchiato' \
  'THEME_DEFAULT_FLAVOUR=latte'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "fedora: the manifest gives theme the default 'macchiato', but platforms/fedora/install.sh starts with theme='latte'"
printf 'PASS: a default stated through a shared library is resolved and compared\n'

# --- An enumerated value set is read by something ---------------------------

# `--theme nonsense` was accepted by the installer, recorded, published in the
# generated reference, and refused by bin/.local/bin/theme at the end of the
# install: the registry's list and the runtime's case statement were two
# hand-written lists with no gate between them.
test_new_root
manifest="$TEST_ROOT/extra-flavour.tsv"
sed 's/latte|frappe|macchiato|mocha/latte|frappe|macchiato|mocha|nonsense/' \
  "$repo_root/config/install-options.tsv" >"$manifest"
run_capture env "INSTALL_OPTION_MANIFEST=$manifest" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "the manifest offers theme 'nonsense', which bin/.local/bin/theme does not cover"
printf 'PASS: a flavour the registry offers and the runtime refuses fails\n'

test_new_root
manifest="$TEST_ROOT/fewer-flavours.tsv"
sed 's/latte|frappe|macchiato|mocha/latte|macchiato|mocha/' \
  "$repo_root/config/install-options.tsv" >"$manifest"
run_capture env "INSTALL_OPTION_MANIFEST=$manifest" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "bin/.local/bin/theme covers theme 'frappe'"
printf 'PASS: a flavour the runtime accepts and the registry drops fails\n'

scratch_tree
replace_line "$tree/bin/.local/bin/theme" '  latte|frappe|macchiato|mocha)' \
  '  latte|macchiato|mocha)'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "the manifest offers theme 'frappe', which bin/.local/bin/theme does not cover"
printf 'PASS: a flavour deleted from the runtime fails against the registry\n'

# An enumeration nothing is held to is documentation, not a contract, so a
# consumer row that goes missing fails rather than quietly relaxing the check.
test_new_root
consumers="$TEST_ROOT/no-consumers.tsv"
head -1 "$repo_root/config/option-consumers.tsv" >"$consumers"
run_capture env "OPTION_CONSUMER_MANIFEST=$consumers" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "macos: the manifest enumerates theme values, but"
assert_contains "$TEST_OUTPUT" "names nothing that reads them"
printf 'PASS: an enumerated option with no declared consumer fails\n'

# A consumer that no longer branches on the value it is registered for is
# unreadable, not compliant.
scratch_tree
replace_line "$tree/bin/.local/bin/theme" 'case "$flavour" in' 'case "${flavour:-}" in'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'no `case "$flavour" in`'
printf 'PASS: a consumer whose case this check cannot find fails\n'


# --- Every shape a consumer states its values in ----------------------------

# The registry was held to one consumer and ten others kept their own copy of
# the four flavours, so a flavour added to the manifest was accepted by the
# installer, recorded, and then ignored by Neovim, missing from Starship and
# refused by the Windows theme script. Each shape below is one of those copies,
# and each case is the drift that used to pass.

scratch_tree
replace_line "$tree/nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua" \
  '    mocha = true,' '    mocha = false,'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "which nvim-lazyvim/.config/nvim/lua/plugins/colorscheme.lua does not cover"
printf 'PASS: a flavour missing from the Neovim table fails\n'

scratch_tree
replace_line "$tree/platforms/windows/set-noctty-theme.ps1" \
  "    [ValidateSet('latte', 'frappe', 'macchiato', 'mocha')]" \
  "    [ValidateSet('latte', 'frappe', 'macchiato')]"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "which platforms/windows/set-noctty-theme.ps1 does not cover"
printf 'PASS: a flavour missing from the PowerShell parameter set fails\n'

scratch_tree
replace_line "$tree/scripts/update-starship-themes.sh" '  mocha' '  # mocha'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "which scripts/update-starship-themes.sh does not cover"
printf 'PASS: a flavour missing from the Starship generator fails\n'

scratch_tree
replace_line "$tree/platforms/macos/scripts/verify.sh" \
  'for flavour in latte frappe macchiato mocha; do' \
  'for flavour in latte frappe macchiato; do'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" "which platforms/macos/scripts/verify.sh does not cover"
printf 'PASS: a flavour a verifier stops checking assets for fails\n'

# The Fedora hook reads two different things through "$1", so the row names the
# function as well: the flavour case, not the Ghostty reload case.
scratch_tree
hook="$tree/platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh"
replace_line "$hook" "  latte) printf 'Catppuccin-Latte-Mauve\n' ;;" \
  "  # latte) printf 'Catppuccin-Latte-Mauve\n' ;;"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" "theme-hooks.d/fedora.sh does not cover"
printf 'PASS: a flavour dropped from a function-scoped case fails\n'

# The asset half: a flavour the registry offers with nothing on disk to stow,
# and a file on disk for a flavour nothing can select.
scratch_tree
rm -f "$tree/theme-assets/.local/share/wallpapers/catppuccin-mocha.webp"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "which theme-assets/.local/share/wallpapers/catppuccin-{value}.webp does not cover"
printf 'PASS: a flavour with no wallpaper on disk fails\n'

scratch_tree
cp "$tree/theme-assets/.local/share/wallpapers/catppuccin-mocha.webp" \
  "$tree/theme-assets/.local/share/wallpapers/catppuccin-espresso.webp"
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" "covers theme 'espresso'"
printf 'PASS: an asset for a flavour the registry does not offer fails\n'

# A lock-screen wallpaper is not a flavour called mocha-lock: the two patterns
# share a directory and a prefix, and reading one as the other would have made
# the whole directory drift from the registry in both directions at once.
run_capture python3 "$repo_root/scripts/validate-install-options.py"
assert_success
printf 'PASS: two file patterns in one directory read as their own values\n'

# A kind the check cannot read is an error: a consumer whose shape is unknown
# enforces nothing, and reading that as agreement is the defect itself.
test_new_root
consumers="$TEST_ROOT/unreadable-kind.tsv"
sed 's/\tshell-case\t/\tvibes\t/' "$repo_root/config/option-consumers.tsv" >"$consumers"
run_capture env "OPTION_CONSUMER_MANIFEST=$consumers" \
  python3 "$repo_root/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" "declares the kind 'vibes', which this check cannot read"
printf 'PASS: a consumer kind this check cannot read fails\n'

# --- The coupled wiring sites a new capability is threaded through -----------
#
# Adding a capability to an installer means editing nine places. The argv arm
# and the default above are two of them; these are the rest. Each case removes
# exactly one and requires the validator to name it, because a check that
# cannot fail is the defect this group exists to prevent: a capability could be
# declared, parsed and recorded while no step ever installed it, and every gate
# stayed green.

fedora_selection_set='install_selection_set tailscale "$install_tailscale"'
fedora_summary_line='Tailscale profile:   $install_tailscale'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_selection_set" ''
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'never calls `install_selection_set tailscale`'
assert_contains "$TEST_OUTPUT" '--rerun forgets the selection'
printf 'PASS: a capability the installer never records fails\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_selection_set" \
  'install_selection_set tailscal "$install_tailscale"'
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'records a tailscal selection'
assert_contains "$TEST_OUTPUT" 'never calls `install_selection_set tailscale`'
printf 'PASS: a selection recorded under a name the manifest does not declare fails, both ways\n'

# The capability list is what the run prints as its selected set. Dropping one
# entry installs the capability without saying so, which the run's own output
# then reads as not selected.
scratch_tree
python3 - "$tree/platforms/fedora/install.sh" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entry = ' "$install_tailscale:tailscale"'
if text.count(entry) != 1:
    sys.exit(f"expected exactly one {entry!r} in {path}")
path.write_text(text.replace(entry, ""), encoding="utf-8")
PYTHON
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" \
  'does not list tailscale among the capabilities it reports as selected'
printf 'PASS: a capability missing from the selected list fails\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" \
  "[[ \"\$install_tailscale\" != true ]] || plan_add tailscale 'Install the optional Tailscale networking profile' apply : apply_tailscale \"\$(plan_command_note fedora_tailscale_command)\" 'platforms/fedora/scripts/install-tailscale.sh'" \
  ''
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'no `plan_add tailscale` step'
assert_contains "$TEST_OUTPUT" 'records the choice and installs nothing'
printf 'PASS: a capability with no execution-plan step fails\n'

scratch_tree
replace_line "$tree/platforms/fedora/install.sh" "$fedora_summary_line" ''
run_capture python3 "$tree/scripts/validate-install-options.py"
assert_failure
assert_contains "$TEST_OUTPUT" 'never shows $install_tailscale'
assert_contains "$TEST_OUTPUT" 'without appearing in the plan the run prints'
printf 'PASS: an option missing from the --dry-run summary fails\n'

# --- The generated --help listing -------------------------------------------
#
# The listing is rendered from the manifest, so it can go stale in two
# directions: the generated file edited by hand, and the manifest changed
# without regenerating. Both are the same gate and both are checked, because a
# gate that only notices one of them leaves the other silent.

run_capture python3 "$repo_root/scripts/render-installer-usage.py" --check
assert_success
printf 'PASS: the committed installer help text matches the manifest\n'

scratch_tree
replace_line "$tree/platforms/fedora/lib/usage-options.sh" \
  '                     Tailscale networking profile (default: false)' \
  '                     Tailscale networking profile, probably (default: false)'
run_capture python3 "$tree/scripts/render-installer-usage.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" 'fedora installer help text is stale'
printf 'PASS: a hand-edited generated help listing fails\n'

# macOS carries the same summary for its own tailscale row, so the line is
# replaced whole: a substring edit would change both platforms' rows and the
# case would stop being about the Fedora listing.
fedora_tailscale_row=$'fedora\ttailscale\tboolean\t--tailscale\t--no-tailscale\tfalse\t-\ttailscale\tTailscale networking profile'

scratch_tree
replace_line "$tree/config/install-options.tsv" "$fedora_tailscale_row" \
  "${fedora_tailscale_row%Tailscale networking profile}Tailscale mesh networking"
run_capture python3 "$tree/scripts/render-installer-usage.py" --check
assert_failure
assert_contains "$TEST_OUTPUT" 'fedora installer help text is stale'
printf 'PASS: a manifest summary changed without regenerating fails\n'

# A platform whose usage() does not call usage_persistent_options has no
# generated listing, and asking for one is an error rather than a file written
# where nothing reads it.
run_capture python3 "$repo_root/scripts/render-installer-usage.py" --platform macos --check
assert_failure
assert_contains "$TEST_OUTPUT" 'not a generated platform: macos'
printf 'PASS: rendering a listing no installer reads fails\n'

printf 'Installer option parser validation passed.\n'
