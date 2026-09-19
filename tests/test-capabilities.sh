#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/validate-capabilities.py"
python3 "$repo_root/scripts/render-capability-matrix.py" --check

fixture="$(mktemp)"
trap 'rm -rf -- "$fixture" "$fixture".*' EXIT
cp "$repo_root/config/capabilities.tsv" "$fixture"
duplicate_row="$(sed -n '2p' "$fixture")"
printf '%s\n' "$duplicate_row" >>"$fixture"
if CAPABILITY_MANIFEST="$fixture" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.log"; then
  printf 'Duplicate provider fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'duplicate provider ownership' "$fixture.log"

awk -F '\t' 'BEGIN {OFS="\t"} NR == 2 {$8="-"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.provider"
if CAPABILITY_MANIFEST="$fixture.provider" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.provider.log"; then
  printf 'Missing provider fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'lacks provider' "$fixture.provider.log"

# config/capabilities.tsv and config/install-options.tsv describe the same CLI
# contract from two directions, so a default may never be changed in one of
# them alone. Each fixture below edits exactly one manifest.

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "latex" {$6 = "false"} {print}' \
  "$repo_root/config/install-options.tsv" >"$fixture.options"
if INSTALL_OPTION_MANIFEST="$fixture.options" \
  python3 "$repo_root/scripts/validate-capabilities.py" 2>"$fixture.options.log"; then
  printf 'Divergent installer-option default fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'fedora/latex' "$fixture.options.log"
grep -Fq 'disagrees with capability latex default' "$fixture.options.log"

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "kde" && $2 == "fedora" {$5 = "disabled"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.capability"
if CAPABILITY_MANIFEST="$fixture.capability" \
  python3 "$repo_root/scripts/validate-capabilities.py" 2>"$fixture.capability.log"; then
  printf 'Divergent capability default fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'fedora/kde' "$fixture.capability.log"
grep -Fq "disagrees with capability kde default 'disabled'" "$fixture.capability.log"

# --dev-workflows is a transient execution control: it has a CLI flag on
# purpose and no persistent option row. The clean run above passes only because
# the validator carries it as an explicit exception; this keeps the exception
# honest by proving the row really is absent.
if awk -F '\t' '$1 == "fedora" && $2 == "dev-workflows" { found = 1 } END { exit !found }' \
  "$repo_root/config/install-options.tsv"; then
  printf 'dev-workflows must not be a persistent installer option.\n' >&2
  exit 1
fi

# A verifier declared for a capability it never mentions is the DOC-004 defect:
# the manifest promises a check that does not exist, and the selected profile
# then passes verification unconditionally. Point the Fedora LaTeX row at a
# platform verifier that knows nothing about LaTeX and the manifest must say so,
# naming both the capability and the file.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "latex" && $2 == "fedora" {$11="platforms/macos/scripts/verify.sh"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.verifier"
if CAPABILITY_MANIFEST="$fixture.verifier" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.verifier.log"; then
  printf 'Verifier that never mentions its capability unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'never mentions latex' "$fixture.verifier.log"
grep -Fq 'platforms/macos/scripts/verify.sh' "$fixture.verifier.log"

# A conflict is a property of a pair. Declared on one side only it fires or not
# depending on which capability a selection is validated from, so the manifest
# must state it on both rows.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "hardware" && $2 == "fedora" {$7 = "-"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.conflict"
if CAPABILITY_MANIFEST="$fixture.conflict" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.conflict.log"; then
  printf 'One-sided conflict fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'hardware does not conflict with vm-guest' "$fixture.conflict.log"

# The packages column is a claim about what gets installed, checked against the
# files that install them in both directions: a package no installer requests,
# and an installer array entry no capability owns.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "hardening" && $2 == "fedora" {$9 = $9 ",policycoreutils-python-utils"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.phantom"
if CAPABILITY_MANIFEST="$fixture.phantom" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.phantom.log"; then
  printf 'Phantom package fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora/hardening: package 'policycoreutils-python-utils' is declared" \
  "$fixture.phantom.log"

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "vm-guest" && $2 == "fedora" {sub(/,xclip/, "", $9)} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.unowned"
if CAPABILITY_MANIFEST="$fixture.unowned" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.unowned.log"; then
  printf 'Unowned installed package fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "vm_guest_packages installs 'xclip', which no fedora capability owns" \
  "$fixture.unowned.log"

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "ai" && $2 == "fedora" {$9 = $9 ",totally-fake-nonexistent-package"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.fabricated"
if CAPABILITY_MANIFEST="$fixture.fabricated" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.fabricated.log"; then
  printf 'Fabricated AI package fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora/ai: package 'totally-fake-nonexistent-package' is declared but is not requested by common/install-ai.sh" \
  "$fixture.fabricated.log"

# A mise configuration is parsed rather than searched, so a package is only
# requested there when it is a declared tool.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "dotnet-debug" && $2 == "fedora" {$9 = "EasyDotnetCli"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.mise"
if CAPABILITY_MANIFEST="$fixture.mise" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.mise.log"; then
  printf 'Undeclared mise tool fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora/dotnet-debug: package 'EasyDotnetCli' is declared but is not requested by mise/.config/mise/config.toml" \
  "$fixture.mise.log"

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "dotnet-debug" && $2 == "macos" {$16 = "-"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.installers"
if CAPABILITY_MANIFEST="$fixture.installers" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.installers.log"; then
  printf 'Package row without installers unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'macos/dotnet-debug: declares packages (EasyDotnet) but names no installers' \
  "$fixture.installers.log"

# Every capability an installer option selects must be implemented on that
# platform; deleting its row is not a silent way to drop it (#242).
awk -F '\t' '!($1 == "hardening" && $2 == "fedora")' \
  "$repo_root/config/capabilities.tsv" >"$fixture.deleted"
if CAPABILITY_MANIFEST="$fixture.deleted" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.deleted.log"; then
  printf 'Deleted implemented capability fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'fedora/hardening: selects capability hardening, which has no implemented fedora row' \
  "$fixture.deleted.log"

# The stow column drives preflight conflict detection, so it must name exactly
# what the Stow scripts deploy on each platform, in both directions (#242).
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "base" && $2 == "fedora" {sub(/,ghostty,/, ",", $10)} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.stow"
if CAPABILITY_MANIFEST="$fixture.stow" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.stow.log"; then
  printf 'Undeclared Stow package fixture unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora: Stow package 'ghostty' is deployed by the Stow scripts but no fedora capability declares it" \
  "$fixture.stow.log"

# Fedora WSL runs the portable Stow script with --headless, which drops Ghostty.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "base" && $2 == "fedora-wsl" {$10 = $10 ",ghostty"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.headless"
if CAPABILITY_MANIFEST="$fixture.headless" python3 "$repo_root/scripts/validate-capabilities.py" \
  2>"$fixture.headless.log"; then
  printf 'Stow package the headless platform never deploys unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora-wsl: Stow package 'ghostty' is declared in the stow column but no Stow script deploys it" \
  "$fixture.headless.log"

# The scripts side needs a scratch copy of the repository: the validator reads
# the Stow scripts next to itself, and this checkout is never modified.
mkdir -p "$fixture.tree"
cp -R "$repo_root/." "$fixture.tree/"
rm -rf -- "$fixture.tree/.git"
printf 'packages+=(nonexistent)\n' >>"$fixture.tree/platforms/fedora/scripts/stow.sh"
if python3 "$fixture.tree/scripts/validate-capabilities.py" 2>"$fixture.tree.log"; then
  printf 'Stow script package no capability declares unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora: Stow package 'nonexistent' is deployed by the Stow scripts but no fedora capability declares it" \
  "$fixture.tree.log"

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/capabilities.sh
source "$repo_root/common/lib/capabilities.sh"
if capability_validate_selection fedora base codex >/dev/null 2>&1; then
  printf 'Selection with an absent dependency unexpectedly passed.\n' >&2
  exit 1
fi
capability_validate_selection fedora base ai codex
capability_validate_selection fedora base hardware
if capability_validate_selection fedora base hardware vm-guest >/dev/null 2>&1; then
  printf 'Hardware and VM-guest conflict unexpectedly passed.\n' >&2
  exit 1
fi

hardware_packages="$(awk -F '\t' '$1=="hardware" && $2=="fedora" {print $9; exit}' \
  "$repo_root/config/capabilities.tsv")"
[[ ",$hardware_packages," != *,supergfxctl,* ]] || {
  printf 'Fedora hardware capability must not own supergfxctl.\n' >&2
  exit 1
}
[[ ",$hardware_packages," == *,asusctl,* ]]
[[ ",$hardware_packages," == *,akmods,* ]]

fedora_installer="$repo_root/platforms/fedora/install.sh"
# The selection is resolved by one function, whose every consumer -- the
# selection check, preflight and the lifecycle record -- calls it.
grep -Fq "\"\$hardware_selected:hardware\"" "$fedora_installer"
[[ "$(grep -Fc 'fedora_selected_capabilities' "$fedora_installer")" -ge 4 ]] || {
  printf 'Fedora hardware selection is not shared by the selection check, preflight and lifecycle capability resolution.\n' >&2
  exit 1
}
# The command a failed run prints is rendered from the resolved selection by
# the shared library, not by a per-platform renderer (#225, DOC-036), so the
# hardware options reach it through the recorded selection.
grep -Fq "DOTFILES_RERUN_COMMAND=\"\$(install_lifecycle_rerun_command fedora \"\$install_selection\")\"" \
  "$fedora_installer"
if grep -Fq 'build_rerun_command' "$fedora_installer"; then
  printf 'Fedora still builds its own rerun command instead of using the shared selection model.\n' >&2
  exit 1
fi
grep -Fq "install_selection_set hardware \"\${hardware_model:--}\"" "$fedora_installer"
# shellcheck disable=SC2016 # Matching the literal assignment in install.sh.
grep -Fq 'install_selection_set secure-boot "$hardware_secure_boot"' "$fedora_installer"
grep -Fq "install_selection_set charge-limit \"\${hardware_charge_limit:--}\"" "$fedora_installer"

hardware_dry_run="$(
  "$repo_root/install.sh" --dry-run --no-kde --no-latex \
    --hardware ga402xz --secure-boot --charge-limit 80
)"
[[ "$hardware_dry_run" == *'ASUS hardware:       ga402xz'* ]]
[[ "$hardware_dry_run" == *'Require Secure Boot: true'* ]]
[[ "$hardware_dry_run" == *'Battery limit:       80'* ]]

grep -Fq 'config/capabilities.tsv' "$repo_root/docs/capabilities.md"

# The platform lists are derived from this manifest, not repeated in each
# generator. Adding a base row must reach the generated pages, and a platform
# without a human-authored title must stop the render rather than produce an
# unlabelled column. Two lists come out of the manifest and they are not the
# same one: every platform it models, and the subset ./install.sh can run.
manifest_platforms="$(awk -F '\t' 'NR > 1 {print $2}' \
  "$repo_root/config/capabilities.tsv" | awk '!seen[$0]++')"
registered_platforms="$(PYTHONPATH="$repo_root/scripts/lib" python3 -c \
  'import manifests; print("\n".join(manifests.registered_platforms()))')"
[[ "$manifest_platforms" == "$registered_platforms" ]] || {
  printf 'The shared platform helper disagrees with the manifest.\n' >&2
  exit 1
}

# The installer's own list is the implemented base rows it has a script for: a
# platform installed by something other than platforms/<name>/install.sh is
# registered without being a --platform name.
installer_platforms=""
while IFS= read -r candidate; do
  [[ -f "$repo_root/platforms/$candidate/install.sh" ]] || continue
  installer_platforms+="${installer_platforms:+$'\n'}$candidate"
done < <(awk -F '\t' 'NR > 1 && $1 == "base" && $15 == "implemented" {print $2}' \
  "$repo_root/config/capabilities.tsv")
helper_platforms="$(PYTHONPATH="$repo_root/scripts/lib" python3 -c \
  'import manifests; print("\n".join(manifests.supported_platforms()))')"
[[ "$installer_platforms" == "$helper_platforms" ]] || {
  printf 'The shared platform helper disagrees with the installers on disk.\n' >&2
  exit 1
}
[[ "$installer_platforms" != *windows* ]] || {
  printf 'The Windows host has no install.sh under platforms/windows/ to run.\n' >&2
  exit 1
}

cp "$repo_root/config/capabilities.tsv" "$fixture.platform"
printf 'base\tplasma9\tworkstation\t-\tenabled\t-\t-\tdnf\t-\t-\tplatforms/fedora/scripts/verify.sh\t-\tdocs/platforms/fedora.md\tnative\timplemented\t-\n' \
  >>"$fixture.platform"
if CAPABILITY_MANIFEST="$fixture.platform" \
  python3 "$repo_root/scripts/render-capability-matrix.py" --check \
  2>"$fixture.platform.log"; then
  printf 'A platform without a column heading unexpectedly rendered.\n' >&2
  exit 1
fi
grep -Fq 'plasma9' "$fixture.platform.log"

# The matrix legend distinguishes a deliberate absence from a pair the manifest
# does not model at all; without it both read as an em dash.
grep -Fq 'not modelled' "$repo_root/docs/reference/capability-matrix.md"

# ---------------------------------------------------------------------------
# The verify direction
#
# Each rule that checks a verifier against its row is proven able to fail: a
# scratch copy of the repository is broken in exactly the way the rule exists
# to catch, and the validator in that copy must reject it, naming the item.
# ---------------------------------------------------------------------------

# Below "$fixture", so the suite's existing EXIT trap removes it.
scratch_root="$fixture.verify"
mkdir -p "$scratch_root"

new_scratch() {
  scratch="$scratch_root/$1"
  mkdir -p "$scratch"
  cp -R "$repo_root/." "$scratch/"
  rm -rf -- "$scratch/.git"
}

expect_scratch_rejected() {
  local name="$1" expected="$2"
  if python3 "$scratch/scripts/validate-capabilities.py" 2>"$scratch_root/$name.log"; then
    printf '%s: the validator accepted the broken scratch copy.\n' "$name" >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$scratch_root/$name.log" || {
    printf '%s: expected the validator to report: %s\n' "$name" "$expected" >&2
    cat "$scratch_root/$name.log" >&2
    exit 1
  }
  printf 'PASS: %s\n' "$name"
}

# A verifier must check the theme, Mason and tmux components its Stow packages
# rely on.
new_scratch components
sed -i '/^section "Theme"$/,/^section "Neovim tooling"$/{/^section "Neovim tooling"$/!d}' \
  "$scratch/platforms/macos/scripts/verify.sh"
expect_scratch_rejected 'a verifier without its theme section is rejected' \
  "macos/base: Stow package 'starship' relies on theme, but platforms/macos/scripts/verify.sh never checks it"

# A verifier reads its packages from the manifest, never a copy of it.
new_scratch package-array
sed -i 's/^for capability in base vm-guest; do$/packages=(bat curl)\n&/' \
  "$scratch/platforms/parrot-ctf/scripts/verify.sh"
expect_scratch_rejected 'a verifier with a literal package list is rejected' \
  'platforms/parrot-ctf/scripts/verify.sh: verifier keeps its own packages=(...) list (bat curl)'

# A verifier, and a verifier it runs, report through the shared library.
new_scratch library
sed -i '/common\/lib\/verify\.sh"$/d' "$scratch/platforms/fedora/scripts/verify-vm-host.sh"
expect_scratch_rejected 'a verifier that does not source the library is rejected' \
  'platforms/fedora/scripts/verify-vm-host.sh: verifier does not source common/lib/verify.sh'

# A declared verifier must be run by the CI tier that can run it. The Fedora
# job runs the dev-workflows verifier inside its integration script and the
# macOS job runs it as a step; with both gone nothing proves it.
new_scratch real-install
sed -i '/test-dev-workflows\.sh/d' "$scratch/.github/workflows/real-install.yml"
python3 "$scratch/scripts/validate-capabilities.py"
sed -i '/test-dev-workflows\.sh/d' "$scratch/tests/integration/fedora-clean-install.sh"
expect_scratch_rejected 'a verifier no real installation runs is rejected' \
  'dev-workflows: verifier scripts/test-dev-workflows.sh is not run by .github/workflows/real-install.yml'

new_scratch mocked-suite
sed -i '/verify-desktop-tools\.sh/d' "$scratch/tests/test-desktop-tools.sh"
expect_scratch_rejected 'a mocked verifier its suite never runs is rejected' \
  'desktop-tools: tests/test-desktop-tools.sh is recorded as the CI evidence for platforms/fedora/scripts/verify-desktop-tools.sh but never runs it'

# Shell reads every manifest column by name (common/lib/manifest.sh), never by
# a position stated in shell. Reordering columns must not change what an
# installer reads, and a header that loses or repeats a column must fail loudly
# naming it instead of answering from whatever sits at the old position. The
# fixtures are scratch copies; the checkout's manifests are never edited.
swap_columns() {
  awk -F '\t' -v first="$2" -v second="$3" 'BEGIN { OFS = "\t" }
    NR == 1 { for (i = 1; i <= NF; i++) { if ($i == first) a = i; if ($i == second) b = i } }
    { value = $a; $a = $b; $b = value; print }' "$1"
}
(
  # shellcheck source=../common/lib/common.sh
  source "$repo_root/common/lib/common.sh"
  # shellcheck source=../common/lib/capabilities.sh
  source "$repo_root/common/lib/capabilities.sh"
  # shellcheck source=../common/lib/install-selection.sh
  source "$repo_root/common/lib/install-selection.sh"

  expect_column_failure() {
    local description="$1" expected="$2" output log
    shift 2
    output="$fixture.column.out"; log="$fixture.column.log"
    if "$@" >"$output" 2>"$log"; then
      printf '%s unexpectedly answered: %s\n' "$description" "$(cat "$output")" >&2
      exit 1
    fi
    grep -Fq "$expected" "$log" || {
      printf '%s did not name the offending column (%s):\n' "$description" "$expected" >&2
      cat "$log" >&2
      exit 1
    }
  }

  swap_columns "$repo_root/config/capabilities.tsv" cli_flag default >"$fixture.swapped"
  [[ "$(CAPABILITY_MANIFEST="$fixture.swapped" capability_field fedora kde cli_flag)" == --kde &&
    "$(CAPABILITY_MANIFEST="$fixture.swapped" capability_field fedora kde default)" == auto ]] || {
    printf 'capability_field read a reordered capability manifest by position.\n' >&2
    exit 1
  }
  sed '1s/\tcli_flag\t/\tcli-flag\t/' "$repo_root/config/capabilities.tsv" >"$fixture.renamed"
  CAPABILITY_MANIFEST="$fixture.renamed" expect_column_failure \
    'A capability manifest without cli_flag' "$fixture.renamed has no column: cli_flag" \
    capability_field fedora kde cli_flag
  sed '1s/\tdefault\t/\tcli_flag\t/' "$repo_root/config/capabilities.tsv" >"$fixture.repeated"
  CAPABILITY_MANIFEST="$fixture.repeated" expect_column_failure \
    'A capability manifest repeating cli_flag' 'repeats column: cli_flag' \
    capability_field fedora kde status
  # The status lookup of a selection check must surface a broken header, not
  # report every capability as merely unimplemented.
  sed '1s/\tstatus\t/\tstate-of-row\t/' "$repo_root/config/capabilities.tsv" >"$fixture.status"
  CAPABILITY_MANIFEST="$fixture.status" expect_column_failure \
    'A selection check against a manifest without status' 'has no column: status' \
    capability_validate_selection fedora base
  # Nor may a lost dependencies column read as "no dependencies".
  sed '1s/\tdependencies\t/\tdeps\t/' "$repo_root/config/capabilities.tsv" >"$fixture.dependencies"
  CAPABILITY_MANIFEST="$fixture.dependencies" expect_column_failure \
    'A selection check against a manifest without dependencies' 'has no column: dependencies' \
    capability_validate_selection fedora base

  # The entry point resolves the platform from the same manifest by name: a
  # moved status or capability column still finds fedora, and a lost column
  # stops the installer naming it rather than listing no supported platforms.
  swap_columns "$repo_root/config/capabilities.tsv" capability status >"$fixture.entry-swapped"
  CAPABILITY_MANIFEST="$fixture.entry-swapped" "$repo_root/install.sh" --platform fedora --help \
    >"$fixture.entry.out" 2>&1 || {
    printf 'The installer entry point read a reordered capability manifest by position:\n' >&2
    cat "$fixture.entry.out" >&2
    exit 1
  }
  grep -Fq 'fedora (default)' "$fixture.entry.out"
  CAPABILITY_MANIFEST="$fixture.status" expect_column_failure \
    'The installer entry point against a manifest without status' 'has no column: status' \
    "$repo_root/install.sh" --platform fedora --help

  swap_columns "$repo_root/config/install-options.tsv" on_flag off_flag >"$fixture.options-swapped"
  [[ "$(INSTALL_OPTION_MANIFEST="$fixture.options-swapped" install_option_field fedora kde on_flag)" == --kde &&
    "$(INSTALL_OPTION_MANIFEST="$fixture.options-swapped" install_option_names fedora)" == "$(install_option_names fedora)" ]] || {
    printf 'install_option_field read a reordered option manifest by position.\n' >&2
    exit 1
  }
  sed '1s/\tkind\t/\ttype\t/' "$repo_root/config/install-options.tsv" >"$fixture.options-renamed"
  INSTALL_OPTION_MANIFEST="$fixture.options-renamed" expect_column_failure \
    'An option manifest without kind' 'has no column: kind' \
    install_option_exists fedora kde

  swap_columns "$repo_root/config/command-providers.tsv" command provider >"$fixture.providers-swapped"
  [[ "$(COMMAND_PROVIDER_MANIFEST="$fixture.providers-swapped" capability_preflight_command_specs fedora)" == \
    "$(capability_preflight_command_specs fedora)" ]] || {
    printf 'capability_preflight_command_specs read a reordered provider manifest by position.\n' >&2
    exit 1
  }
  sed '1s/\tclassification$/\tclass/' "$repo_root/config/command-providers.tsv" >"$fixture.providers-renamed"
  COMMAND_PROVIDER_MANIFEST="$fixture.providers-renamed" expect_column_failure \
    'A provider manifest without classification' 'has no column: classification' \
    capability_preflight_command_specs fedora
)

# ---------------------------------------------------------------------------
# Every platform in the tree is a registered platform
#
# The registry is what makes the platforms answerable to one another, so which
# platforms exist has to come from the tree rather than from a constant in a
# Python file that can be forgotten. These checks derive the list from the
# directories under platforms/ and hold the manifest and the validator to it:
# a new platform fails the build until it is registered, whether or not it is
# one ./install.sh can run.
# ---------------------------------------------------------------------------

platform_constant() {
  python3 - "$1" <<'PY'
import importlib.util
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "validate_capabilities", root / "scripts" / "validate-capabilities.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("\n".join(sorted(module.PLATFORMS)))
PY
}

# Every problem with one checkout's platform registration, one per line.
platform_registration_problems() {
  local root="$1" manifest directory platform script named
  local -a scripts=()
  manifest="$root/config/capabilities.tsv"
  for directory in "$root"/platforms/*/; do
    platform="${directory%/}"
    platform="${platform##*/}"
    if ! awk -F '\t' -v p="$platform" \
      'NR > 1 && $2 == p { found = 1 } END { exit !found }' "$manifest"; then
      printf '%s: a directory under platforms/ with no row in config/capabilities.tsv\n' \
        "$platform"
      continue
    fi
    # A platform verifier is the one script a row can declare for the platform
    # as a whole; the optional profiles' verifiers are declared by their own
    # rows and are checked by the rules above.
    scripts=()
    for script in "${directory}scripts/verify.sh" "${directory}verify.ps1"; do
      [[ -f "$script" ]] || continue
      scripts+=("${script#"$root/"}")
    done
    ((${#scripts[@]} > 0)) || continue
    named=false
    for script in "${scripts[@]}"; do
      if awk -F '\t' -v p="$platform" -v v="$script" \
        'NR > 1 && $2 == p && $11 == v && $15 == "implemented" { found = 1 }
         END { exit !found }' "$manifest"; then
        named=true
      fi
    done
    [[ "$named" == true ]] || printf \
      '%s: has a verifier (%s) that no implemented row declares\n' \
      "$platform" "${scripts[*]}"
  done

  local directories constant
  directories="$(for directory in "$root"/platforms/*/; do
    directory="${directory%/}"
    printf '%s\n' "${directory##*/}"
  done | sort)"
  constant="$(platform_constant "$root")"
  [[ "$directories" == "$constant" ]] || printf \
    'scripts/validate-capabilities.py PLATFORMS is %s, but platforms/ holds %s\n' \
    "$(printf '%s' "$constant" | tr '\n' ' ')" \
    "$(printf '%s' "$directories" | tr '\n' ' ')"
}

registration_problems="$(platform_registration_problems "$repo_root")"
[[ -z "$registration_problems" ]] || {
  printf 'Platform registration is incomplete:\n%s\n' "$registration_problems" >&2
  exit 1
}

# Every platform the tree has must be registered, including the Windows host,
# which has no install.sh under platforms/windows/ and is therefore absent from
# the installer's own list above.
for expected_platform in fedora fedora-wsl macos parrot-ctf windows; do
  awk -F '\t' -v p="$expected_platform" \
    'NR > 1 && $2 == p { found = 1 } END { exit !found }' \
    "$repo_root/config/capabilities.tsv" || {
    printf 'config/capabilities.tsv has no %s row.\n' "$expected_platform" >&2
    exit 1
  }
done
awk -F '\t' '$2 == "windows" && $11 != "platforms/windows/verify.ps1" && $15 == "implemented" {
  printf "An implemented windows row declares %s rather than the Windows verifier.\n", $11
  bad = 1
}
END { exit bad }' "$repo_root/config/capabilities.tsv" || exit 1

# The negative control: a sixth platform directory, with a verifier and no
# rows, must fail this check until it is registered.
new_scratch unregistered-platform
mkdir -p "$scratch/platforms/plasma9/scripts"
cp "$repo_root/platforms/fedora/scripts/verify.sh" \
  "$scratch/platforms/plasma9/scripts/verify.sh"
unregistered="$(platform_registration_problems "$scratch")"
printf '%s\n' "$unregistered" | grep -Fq \
  'plasma9: a directory under platforms/ with no row in config/capabilities.tsv' || {
  printf 'An unregistered platform directory was not reported:\n%s\n' "$unregistered" >&2
  exit 1
}
printf '%s\n' "$unregistered" | grep -Fq \
  'scripts/validate-capabilities.py PLATFORMS is' || {
  printf 'An unregistered platform was not reported against the validator list:\n%s\n' \
    "$unregistered" >&2
  exit 1
}
printf 'PASS: an unregistered platform directory is rejected\n'

printf 'Capability manifest validation passed.\n'
