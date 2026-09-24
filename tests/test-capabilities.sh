#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/source-code.sh
source "$repo_root/tests/lib/source-code.sh"
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

# The two manifests are joined on the flag, but the installer wiring gates in
# scripts/validate-install-options.py key on the option's capability cell and
# skip a row whose cell is `-`, as the plain settings (theme, charge limit)
# legitimately are. A `-` written into the row of a real capability therefore
# switched those gates off with nothing to notice (issue #509): blank the
# `fedora sway` cell, drop sway from fedora_selected_capabilities, and both
# validators passed while --sway bypassed capability_validate_selection. Only
# this registry knows --sway is a capability, so the loop is closed here. Each
# fixture edits exactly one manifest and must name both the flag and the
# capability it belongs to.
#
# Usage: expect_option_link_failure LABEL OPTIONS CAPABILITIES NEEDLE...
expect_option_link_failure() {
  local label="$1" options="$2" capabilities="$3" log="$fixture.link.log" needle
  shift 3
  if INSTALL_OPTION_MANIFEST="$options" CAPABILITY_MANIFEST="$capabilities" \
    python3 "$repo_root/scripts/validate-capabilities.py" 2>"$log"; then
    printf '%s unexpectedly passed.\n' "$label" >&2
    exit 1
  fi
  for needle in "$@"; do
    grep -Fq -- "$needle" "$log" || {
      printf '%s failed without naming %s:\n' "$label" "$needle" >&2
      cat "$log" >&2
      exit 1
    }
  done
}

# Obvious: the option row is gone altogether.
awk -F '\t' '!($1 == "fedora" && $2 == "sway")' \
  "$repo_root/config/install-options.tsv" >"$fixture.options-nosway"
expect_option_link_failure 'Deleted fedora sway option' \
  "$fixture.options-nosway" "$repo_root/config/capabilities.tsv" \
  'fedora/sway: no persistent option declares --sway on fedora'

# Subtle: the row is still there with the right flag, only its capability
# cell says it selects nothing.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "sway" {$8 = "-"} {print}' \
  "$repo_root/config/install-options.tsv" >"$fixture.options-blank"
expect_option_link_failure 'Blank capability cell on fedora sway' \
  "$fixture.options-blank" "$repo_root/config/capabilities.tsv" \
  "fedora/sway: --sway selects capability sway in the capability manifest, but the option's capability cell is '-'"

# Subtle: the cell names a capability, just not the one the flag belongs to.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "sway" {$8 = "kde"} {print}' \
  "$repo_root/config/install-options.tsv" >"$fixture.options-other"
expect_option_link_failure 'Fedora sway option selecting kde' \
  "$fixture.options-other" "$repo_root/config/capabilities.tsv" \
  "fedora/sway: --sway selects capability sway in the capability manifest, but the option's capability cell names kde"

# Subtle: a second row for the same flag. A lookup keyed on the flag keeps
# only the last one, so the duplicate has to be reported, not collapsed.
{
  cat "$repo_root/config/install-options.tsv"
  awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "sway" {$2 = "sway-again"; print}' \
    "$repo_root/config/install-options.tsv"
} >"$fixture.options-dup"
expect_option_link_failure 'Duplicated fedora --sway option' \
  "$fixture.options-dup" "$repo_root/config/capabilities.tsv" \
  'fedora: --sway is the on_flag of more than one option (sway, sway-again)' \
  'fedora: capability sway is selected by more than one option (sway, sway-again)'

# Reverse, from the option side: a `-` row whose flag a capability claims.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "fedora" && $2 == "tailscale" {$8 = "-"} {print}' \
  "$repo_root/config/install-options.tsv" >"$fixture.options-tailscale"
expect_option_link_failure 'Blank capability cell on fedora tailscale' \
  "$fixture.options-tailscale" "$repo_root/config/capabilities.tsv" \
  "fedora/tailscale: --tailscale selects capability tailscale in the capability manifest, but the option's capability cell is '-'"

# Reverse, from the capability side: a capability that claims the flag of a
# plain setting. The option row is untouched and still selects nothing.
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "hardening" && $2 == "fedora" {$4 = "--secure-boot"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$fixture.capability-claims"
expect_option_link_failure 'Fedora hardening claiming --secure-boot' \
  "$repo_root/config/install-options.tsv" "$fixture.capability-claims" \
  "fedora/secure-boot: --secure-boot selects capability hardening in the capability manifest, but the option's capability cell is '-'" \
  "fedora/hardening: selects capability hardening with --hardening, but the capability manifest gives hardening the flag '--secure-boot' on fedora"

# The same blank, for every option whose flag the capability manifest claims:
# no such row may be blanked without the check naming its flag and its
# capability. Run in one process against check_option_manifest() alone, so the
# sweep costs one interpreter start rather than a full validation per row.
python3 - "$repo_root" "$fixture.sweep" <<'PY'
import contextlib
import importlib.util
import io
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
scratch = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "validate_capabilities", root / "scripts" / "validate-capabilities.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
rows = module.read_tsv(module.MANIFEST, module.FIELDS)
lines = module.OPTION_MANIFEST.read_text(encoding="utf-8").splitlines(keepends=True)
header = lines[0].rstrip("\n").split("\t")
column = {name: index for index, name in enumerate(header)}
claimed = {
    (row["platform"], row["cli_flag"]): row["capability"]
    for row in rows
    if row["cli_flag"] not in {"", "-"}
}
swept = 0
missed = []
for number, line in enumerate(lines[1:], 1):
    cells = line.rstrip("\n").split("\t")
    platform, flag = cells[column["platform"]], cells[column["on_flag"]]
    capability = cells[column["capability"]]
    if capability in {"", "-"} or (platform, flag) not in claimed:
        continue
    swept += 1
    cells[column["capability"]] = "-"
    scratch.write_text(
        "".join(lines[:number]) + "\t".join(cells) + "\n" + "".join(lines[number + 1:]),
        encoding="utf-8",
    )
    module.OPTION_MANIFEST = scratch
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        errors = module.check_option_manifest(rows)
    needle = f"{flag} selects capability {capability} in the capability manifest"
    if not errors or needle not in stderr.getvalue():
        missed.append(f"{platform} {flag} ({capability})")
if not swept:
    sys.exit("the blank-cell sweep found no option row to blank")
if missed:
    sys.exit("blanking the capability cell went unreported for: " + ", ".join(missed))
PY

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

awk -F '\t' 'BEGIN {OFS="\t"} $1 == "dotnet-debug" && $2 == "macos" {$17 = "-"} {print}' \
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

# The same append with a declaration keyword in front of it. The Stow reader
# was anchored the same way the installer one was, so `declare -a packages+=(…)`
# read as no append at all: the branch's own packages vanished from the answer
# along with the unowned one, and nothing was compared against the registry.
mkdir -p "$fixture.declared-tree"
cp -R "$repo_root/." "$fixture.declared-tree/"
rm -rf -- "$fixture.declared-tree/.git"
python3 - "$fixture.declared-tree/platforms/fedora/scripts/stow.sh" <<'PYTHON'
import pathlib
import sys

script = pathlib.Path(sys.argv[1])
text = script.read_text(encoding="utf-8")
append = "  packages+=(sway waybar)"
if text.count(append) != 1:
    raise SystemExit(f"expected exactly one {append!r} in {script}")
script.write_text(
    text.replace(append, "  declare -a packages+=(sway waybar unowned-stow-pkg)", 1),
    encoding="utf-8",
)
PYTHON
if python3 "$fixture.declared-tree/scripts/validate-capabilities.py" \
  2>"$fixture.declared-tree.log"; then
  printf 'A declared Stow append hid an unowned package.\n' >&2
  exit 1
fi
grep -Fq "fedora: Stow package 'unowned-stow-pkg' is deployed by the Stow scripts but no fedora capability declares it" \
  "$fixture.declared-tree.log"
printf 'PASS: a Stow append behind a declaration keyword is still read\n'

# A commented-out array entry installs nothing, so a row may not keep claiming
# the package. The installer is read as shell rather than as text, which is the
# only way this fails: `# ripgrep` still contains the word `ripgrep`. Copied
# with tar so the working trees under .claude are left out.
mkdir -p "$fixture.commented"
tar -C "$repo_root" --exclude=.git --exclude=.claude -cf - . |
  tar -C "$fixture.commented" -xf -
sed -i 's/^  ripgrep$/  # ripgrep/' \
  "$fixture.commented/platforms/fedora/scripts/install-system.sh"
if python3 "$fixture.commented/scripts/validate-capabilities.py" \
  2>"$fixture.commented.log"; then
  printf 'Commented-out installer package unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq "fedora/base: package 'ripgrep' is declared but is not requested by platforms/fedora/scripts/install-system.sh" \
  "$fixture.commented.log"

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
code_grep -Fq "\"\$hardware_selected:hardware\"" "$fedora_installer"
[[ "$(grep -Fc 'fedora_selected_capabilities' "$fedora_installer")" -ge 4 ]] || {
  printf 'Fedora hardware selection is not shared by the selection check, preflight and lifecycle capability resolution.\n' >&2
  exit 1
}
# The command a failed run prints is rendered from the resolved selection by
# the shared library, not by a per-platform renderer (#225, DOC-036), so the
# hardware options reach it through the recorded selection.
code_grep -Fq "DOTFILES_RERUN_COMMAND=\"\$(install_lifecycle_rerun_command fedora \"\$install_selection\" \"\${rerun_controls[@]}\")\"" \
  "$fedora_installer"
if code_grep -Fq 'build_rerun_command' "$fedora_installer"; then
  printf 'Fedora still builds its own rerun command instead of using the shared selection model.\n' >&2
  exit 1
fi
code_grep -Fq "install_selection_set hardware \"\${hardware_model:--}\"" "$fedora_installer"
# shellcheck disable=SC2016 # Matching the literal assignment in install.sh.
code_grep -Fq 'install_selection_set secure-boot "$hardware_secure_boot"' "$fedora_installer"
code_grep -Fq "install_selection_set charge-limit \"\${hardware_charge_limit:--}\"" "$fedora_installer"

hardware_dry_run="$(
  "$repo_root/install.sh" --dry-run --no-kde --no-latex \
    --hardware ga402xz --secure-boot --charge-limit 80
)"
[[ "$hardware_dry_run" == *'ASUS hardware model: ga402xz'* ]]
[[ "$hardware_dry_run" == *'Require Secure Boot for the selected hardware: true'* ]]
[[ "$hardware_dry_run" == *'ASUS battery charge limit: 80'* ]]

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
done < <(awk -F '\t' 'NR > 1 && $1 == "base" && $16 == "implemented" {print $2}' \
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
printf 'base\tplasma9\tworkstation\t-\tenabled\t-\t-\tdnf\t-\t-\tplatforms/fedora/scripts/verify.sh\t-\t-\tdocs/platforms/fedora.md\tnative\timplemented\t-\t-\n' \
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

# A verifier being run is not the capability being installed. These rows all
# declare a shared platform verifier that every real-install job runs, so the
# rule above says nothing about them: what has to be true is that some
# ./install.sh invocation actually *selects* them.
new_scratch selection-fedora
sed -i 's/--kde --sway --no-latex/--no-kde --no-latex/g' \
  "$scratch/tests/integration/fedora-clean-install.sh"
expect_scratch_rejected 'a Fedora capability the integration script stops selecting is rejected' \
  'fedora/sway: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --sway'

new_scratch selection-macos
sed -i 's/--ocaml --tailscale --defaults/--ocaml --no-tailscale --defaults/' \
  "$scratch/.github/workflows/real-install.yml"
expect_scratch_rejected 'a macOS capability the workflow stops selecting is rejected' \
  'macos/tailscale: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --tailscale'

# The escape hatch is a registry value, not silence. Deleting the recorded
# reason puts the capability straight back under the rule.
new_scratch selection-exclusion
sed -i 's/\texcluded:[^\t]*$/\t-/' "$scratch/config/capabilities.tsv"
expect_scratch_rejected 'a capability whose CI exclusion is deleted is rejected' \
  "macos/dictation: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --dictation"

# Nor may the reason be anything the schema does not recognise.
new_scratch selection-scope-value
sed -i 's/\texcluded:needs a desktop session[^\t]*$/\tnot-in-ci/' \
  "$scratch/config/capabilities.tsv"
expect_scratch_rejected 'an unrecognised ci_scope value is rejected' \
  "macos/dictation: ci_scope must be '-' or 'excluded:<why>'; got 'not-in-ci'"

# An exclusion that stopped being true is a false claim in the registry, so it
# fails rather than sitting there outranking the workflow.
new_scratch selection-stale-exclusion
sed -i 's/^\(sway\tfedora\t.*\)\t-$/\1\texcluded:needs a compositor/' \
  "$scratch/config/capabilities.tsv"
expect_scratch_rejected 'a CI exclusion the workflow contradicts is rejected' \
  'fedora/sway: ci_scope excludes it from CI, but .github/workflows/real-install.yml selects --sway'

# Selection is read out of the invocation, not searched for in the file: the
# flag written in a step name or a comment is not a machine that installed it.
new_scratch selection-mention-only
sed -i 's/--kde --sway --no-latex/--no-kde --no-latex/g' \
  "$scratch/tests/integration/fedora-clean-install.sh"
sed -i "s|^      - name: Run clean install, verifier, rerun and state transition\$|      - name: Run clean install with --kde --sway|" \
  "$scratch/.github/workflows/real-install.yml"
expect_scratch_rejected 'a flag named only in a step title is not selection' \
  'fedora/kde: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --kde'

# Evidence is per platform. Twelve rows claimed a real installation because
# the flags were read as one flat set, so --ocaml and the five AI flags on the
# macOS job satisfied the Fedora and Fedora WSL rows as well; nothing on those
# platforms had ever passed them.
new_scratch selection-other-platform
sed -i 's/  --ocaml --ai --codex --firstmate --gnhf --backpass --non-interactive/  --ai --codex --firstmate --gnhf --backpass --non-interactive/' \
  "$scratch/tests/integration/fedora-clean-install.sh"
grep -Fq -- '--ocaml' "$scratch/.github/workflows/real-install.yml" ||
  _test_die 'the macOS job must still pass --ocaml, or this case proves nothing'
expect_scratch_rejected 'a flag passed only on another platform is not evidence here' \
  'fedora/ocaml: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --ocaml'

# A rerun replays a selection rather than stating one, so it names no platform
# and is evidence for none: the flags it reinstalls are counted where they were
# first passed.
new_scratch selection-rerun-only
sed -i 's/^          \.\/install\.sh --platform macos --theme mocha$/          .\/install.sh --rerun/' \
  "$scratch/.github/workflows/real-install.yml"
expect_scratch_rejected 'a bare --rerun is not selection for any platform' \
  'macos/ocaml: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --ocaml'

# Selecting a flag is not installing it. Two invocations in this workflow pass
# flags and install nothing, and each was enough on its own to satisfy a row.
#
# The first is the Fedora sequence's negative run, whose *failure* is the
# assertion: an invalid package is injected and the installer has to abort. It
# passes --kde and --sway, so the positive sequence could stop selecting KDE
# with fedora/kde still claiming a real installation. Its
# `# ci-selection: not-an-installation` annotation is what takes it out of the
# walk, and this case proves the annotation is load-bearing rather than
# decorative.
new_scratch selection-expect-failure
sed -i "s|^install_command='./install.sh --platform fedora --kde --sway --no-latex \\\\$|install_command='./install.sh --platform fedora --sway --no-latex \\\\|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
grep -Fq -- '--kde' "$scratch/tests/integration/fedora-clean-install.sh" ||
  _test_die 'the negative run must still pass --kde, or this case proves nothing'
expect_scratch_rejected 'a flag passed only by a run asserted to fail is not evidence' \
  'fedora/kde: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --kde'

# The second is a dry run, which resolves the plan and stops. It needs no
# annotation because --dry-run says it itself.
new_scratch selection-dry-run
sed -i "s|^install_command='./install.sh --platform fedora --kde --sway --no-latex \\\\$|install_command='./install.sh --platform fedora --sway --no-latex \\\\|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
sed -i "s|^base_command='.*$|base_command='./install.sh --platform fedora --sway --no-latex --non-interactive'|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
sed -i "s|^printf '\\\\n==> Clean Fedora installation\\\\n'$|run_as_user './install.sh --platform fedora --kde --dry-run'\n\nprintf '\\\\n==> Clean Fedora installation\\\\n'|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
grep -Fq -- '--kde --dry-run' "$scratch/tests/integration/fedora-clean-install.sh" ||
  _test_die 'the dry run must pass --kde, or this case proves nothing'
expect_scratch_rejected 'a flag passed only by a dry run is not evidence' \
  'fedora/kde: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --kde'

# Carrying the annotations through is what lets the walk see them, and a
# comment is still not something CI runs. Nothing skips comments here: an
# annotation fences the line it is written on, so one that quotes an invocation
# fences that invocation out by the rule that fences the real one below it.
#
# Unlike the four above, this one is not a regression: it pins a property of an
# annotation that did not exist before, so there is nothing for it to have
# caught, and against the pre-fix tree it passes for an unrelated reason -- the
# seds leave --kde nowhere at all, which that tree rejects correctly. It earns
# its place by holding the property once the fence is here, not by having
# failed beforehand.
new_scratch selection-annotation-comment
sed -i "s|^install_command='./install.sh --platform fedora --kde --sway --no-latex \\\\$|install_command='./install.sh --platform fedora --sway --no-latex \\\\|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
sed -i "s|^base_command='.*$|base_command='./install.sh --platform fedora --sway --no-latex --non-interactive'|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
sed -i "s|^# ci-selection: not-an-installation an injected.*$|# ci-selection: not-an-installation ./install.sh --platform fedora --kde would install it|" \
  "$scratch/tests/integration/fedora-clean-install.sh"
expect_scratch_rejected 'an invocation quoted inside an annotation is not selection' \
  'fedora/kde: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --kde'

# A fence is a claim, so a claim this walk cannot act on is a build error
# rather than a comment it skips: a misspelled one would silently leave the row
# resting on the run whose failure is asserted.
new_scratch selection-unknown-claim
sed -i 's/ci-selection: not-an-installation an injected/ci-selection: not-an-instalation an injected/' \
  "$scratch/tests/integration/fedora-clean-install.sh"
expect_scratch_rejected 'an unrecognised ci-selection claim is rejected' \
  "unknown ci-selection claim 'not-an-instalation'"

# And a fence with no reason is one nobody can review, like a ci_scope
# exclusion with no why.
new_scratch selection-unexplained-fence
sed -i 's/ci-selection: not-an-installation an injected invalid package aborts this run/ci-selection: not-an-installation/' \
  "$scratch/tests/integration/fedora-clean-install.sh"
expect_scratch_rejected 'a ci-selection fence with no reason is rejected' \
  'must say why this invocation installs nothing'

# A package is what an installer asks for, not what it says. Dropping
# kio-extras from the KDE installer's dnf array and naming it in a message, or
# in a heredoc body, left the row still claiming to own Dolphin's sftp://
# support while nothing installed it.
new_scratch requested-in-message
sed -i 's/^packages=(kio-extras wget)$/packages=(wget)/' \
  "$scratch/platforms/fedora/scripts/install-kde-theme.sh"
sed -i 's/    info "\$package is already installed"/    info "kio-extras and $package are already installed"/' \
  "$scratch/platforms/fedora/scripts/install-kde-theme.sh"
grep -Fq 'info "kio-extras and $package are already installed"' \
  "$scratch/platforms/fedora/scripts/install-kde-theme.sh" ||
  _test_die 'the message fixture did not apply, so this case proves nothing'
expect_scratch_rejected 'a package named only in a message is not an install' \
  "fedora/kde: package 'kio-extras' is declared but is not requested by"

new_scratch requested-in-heredoc
sed -i 's/^packages=(kio-extras wget)$/packages=(wget)/' \
  "$scratch/platforms/fedora/scripts/install-kde-theme.sh"
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "platforms/fedora/scripts/install-kde-theme.sh"
text = path.read_text(encoding="utf-8")
old = '    info "$package is already installed"'
if text.count(old) != 1:
    sys.exit("expected exactly one already-installed message to replace")
body = "    cat <<EOF_NOTE\nkio-extras is provided by the KDE profile\nEOF_NOTE"
path.write_text(text.replace(old, body), encoding="utf-8")
PYTHON
expect_scratch_rejected 'a package named only in a heredoc body is not an install' \
  "fedora/kde: package 'kio-extras' is declared but is not requested by"

# The other direction of the same rule: content a script really writes is not a
# message. The AI profile composes its mise tool list with printf, which is the
# only place herdr is asked for, and that must keep counting.
new_scratch requested-by-printf
grep -Fq "printf 'herdr = \"latest\"" "$scratch/common/install-ai.sh" ||
  _test_die 'the AI installer no longer composes its tool list with printf'
python3 "$scratch/scripts/validate-capabilities.py" ||
  _test_die 'a package a printf really writes must still count as requested'
printf 'PASS: a package written by a printf that composes content still counts\n'

# A workflow is not a script, so only the shell a step runs is evidence that
# CI runs anything. A step that names a verifier in its `name:` runs nothing,
# and used to satisfy the rule that the verifier is proven by a real install.
new_scratch ci-evidence-step-name
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
lines = path.read_text(encoding="utf-8").splitlines()
verifier = "./platforms/parrot-ctf/scripts/verify.sh"
if sum(line.strip() == verifier for line in lines) < 1:
    sys.exit("the Parrot job no longer runs its verifier, so this case proves nothing")
kept = []
for line in lines:
    if line.strip() == verifier:
        kept.append(line.replace(verifier, "true"))
    elif line.strip().startswith("- name:") and "Verify" in line:
        kept.append(f"{line} with {verifier}")
    else:
        kept.append(line)
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
expect_scratch_rejected 'a verifier named only in a step name is not run by CI' \
  'verifier platforms/parrot-ctf/scripts/verify.sh is not run by .github/workflows/real-install.yml'

# The same rule decides which flags a real installation passed, so an
# invocation written into a step's name is not that invocation either. Here
# the whole macOS transition install moves into the step name it already had,
# which the old reader accepted as the selection it describes.
new_scratch ci-evidence-named-invocation
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
lines = path.read_text(encoding="utf-8").splitlines()
first = next(
    (
        index
        for index, line in enumerate(lines)
        if line.strip() == "./install.sh --platform macos --theme mocha"
    ),
    None,
)
if first is None:
    sys.exit("the macOS transition install has moved, so this case proves nothing")
last = next(
    index for index in range(first, len(lines)) if lines[index].strip() == "--non-interactive"
)
invocation = " ".join(lines[index].strip() for index in range(first, last + 1))
step = next(index for index in range(first, -1, -1) if lines[index].lstrip().startswith("- name:"))
run = next(index for index in range(first, -1, -1) if lines[index].strip().startswith("run:"))
kept = lines[:step]
kept.append(f"      - name: Ran {invocation}")
kept.extend(lines[step + 1:run])
kept.append("        run: true")
kept.extend(lines[last + 1:])
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
expect_scratch_rejected 'an invocation written in a step name selects nothing' \
  'macos/ocaml: no ./install.sh invocation in .github/workflows/real-install.yml, or in a script it runs, passes --ocaml'

# Shell in command position is not the same as shell that runs something. A
# step that echoes a verifier's path runs nothing, and the run-block reader
# alone could not tell the two apart, so six macOS rows kept their CI evidence
# while the verifier was commented out in all but name.
new_scratch ci-evidence-echoed
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
verifier = "./platforms/macos/scripts/verify.sh"
runs = {verifier, f"{verifier} --defaults"}
lines = path.read_text(encoding="utf-8").splitlines()
if not any(line.strip() in runs or line.strip() == f"run: {verifier}" for line in lines):
    sys.exit("the macOS job no longer runs its verifier, so this case proves nothing")
kept = []
for line in lines:
    stripped = line.strip()
    if stripped in runs or stripped == f"run: {verifier}":
        indent = line[: len(line) - len(line.lstrip())]
        prefix = "run: " if stripped.startswith("run: ") else ""
        kept.append(f'{indent}{prefix}echo "skipping {verifier} for now"')
    else:
        kept.append(line)
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
expect_scratch_rejected 'a verifier a step only echoes is not run by CI' \
  'verifier platforms/macos/scripts/verify.sh is not run by .github/workflows/real-install.yml'

# The same words on a line that also runs something are not the whole line:
# only what the reporting command prints is dropped, so the real invocation
# after it still counts. Without this the fix would trade one blind spot for
# the opposite one.
new_scratch ci-evidence-echoed-then-run
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
verifier = "./platforms/parrot-ctf/scripts/verify.sh"
lines = path.read_text(encoding="utf-8").splitlines()
replaced = 0
kept = []
for line in lines:
    if line.strip() == verifier:
        indent = line[: len(line) - len(line.lstrip())]
        kept.append(f'{indent}echo "about to run {verifier}" && {verifier}')
        replaced += 1
    else:
        kept.append(line)
if not replaced:
    sys.exit("the Parrot job no longer runs its verifier, so this case proves nothing")
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
python3 "$scratch/scripts/validate-capabilities.py" ||
  _test_die 'an invocation after a message on the same line must still count'
printf 'PASS: a message before a real invocation does not hide it\n'

# An operator the message merely prints does not end the message. Taking `&&`
# as spelled would read the rest of the string as code, which reopens the hole
# one character further along: the echo still runs nothing.
new_scratch ci-evidence-echoed-operator
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
verifier = "./platforms/macos/scripts/verify.sh"
runs = {verifier, f"{verifier} --defaults"}
lines = path.read_text(encoding="utf-8").splitlines()
if not any(line.strip() in runs or line.strip() == f"run: {verifier}" for line in lines):
    sys.exit("the macOS job no longer runs its verifier, so this case proves nothing")
kept = []
for line in lines:
    stripped = line.strip()
    if stripped in runs or stripped == f"run: {verifier}":
        indent = line[: len(line) - len(line.lstrip())]
        prefix = "run: " if stripped.startswith("run: ") else ""
        kept.append(f'{indent}{prefix}echo "skipped: would have been && {verifier}"')
    else:
        kept.append(line)
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
expect_scratch_rejected 'an operator inside a message does not start a command' \
  'verifier platforms/macos/scripts/verify.sh is not run by .github/workflows/real-install.yml'

# The reader must fail loudly rather than find nothing: a workflow it cannot
# take a single `run:` block out of would otherwise prove every verifier.
new_scratch ci-evidence-unreadable
python3 - "$scratch" <<'PYTHON'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1]) / ".github/workflows/real-install.yml"
text = path.read_text(encoding="utf-8")
if "run:" not in text:
    sys.exit("the workflow has no run steps, so this case proves nothing")
path.write_text(re.sub(r"(?m)^(\s*(?:-\s+)?)run:", r"\1shell-script:", text), encoding="utf-8")
PYTHON
expect_scratch_rejected 'a workflow with no readable run block is an error, not a pass' \
  'no `run:` step could be read'

# A comment is not a check. Deleting a verifier's whole LaTeX section and
# leaving one comment line behind used to satisfy the rule that exists to
# notice exactly that; only the `# verifies:` marker may speak from a comment.
new_scratch mention-comment-only
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "platforms/fedora/scripts/verify.sh"
lines = path.read_text(encoding="utf-8").splitlines()
start = next(index for index, line in enumerate(lines) if "latex" in line.lower())
end = next(
    (
        index
        for index in range(start + 1, len(lines))
        if lines[index].startswith('section "') and "latex" not in lines[index].lower()
    ),
    len(lines),
)
kept = lines[:start] + ["# TODO: the latex checks were removed"] + lines[end:]
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
expect_scratch_rejected 'a verification section replaced by a comment is rejected' \
  'verifier platforms/fedora/scripts/verify.sh never mentions latex'

# The marker is the one thing a comment may say, so a section that performs a
# check the capability's name does not appear in still passes when it is marked.
new_scratch mention-marker
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "latex" && $2 == "fedora" {$11="platforms/macos/scripts/verify.sh"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$scratch/config/capabilities.tsv"
if python3 "$scratch/scripts/validate-capabilities.py" 2>/dev/null; then
  printf 'mention-marker: the unmarked control passed, so this case proves nothing.\n' >&2
  exit 1
fi
sed -i '2i # verifies: latex' "$scratch/platforms/macos/scripts/verify.sh"
python3 "$scratch/scripts/validate-capabilities.py" || {
  printf 'mention-marker: a section carrying the verifies marker must pass.\n' >&2
  exit 1
}
printf 'PASS: an explicit verifies marker is accepted where the name is absent\n'

# Every declared verifier is held to the rule, not only platforms/*/verify.sh:
# a row naming a dedicated verifier used to get no mention check at all.
new_scratch mention-dedicated
awk -F '\t' 'BEGIN {OFS="\t"} $1 == "containers" && $2 == "fedora" {$11="platforms/fedora/scripts/verify-tailscale.sh"} {print}' \
  "$repo_root/config/capabilities.tsv" >"$scratch/config/capabilities.tsv"
expect_scratch_rejected 'a dedicated verifier that never mentions its capability is rejected' \
  'verifier platforms/fedora/scripts/verify-tailscale.sh never mentions containers'

# The schema a component state file must declare is registry data, because
# scripts/doctor.sh compares a machine's state files against it (#342). Each of
# the three rules that keeps it honest is proven able to fail.

# The column is found by its header name, like every reader in this
# repository: a fixture that edited a fixed position would quietly start
# breaking a different column if the manifest were ever reordered, and this
# control would pass on the wrong error.
set_state_profile() {
  awk -F '\t' -v capability="$1" -v platform="$2" -v value="$3" 'BEGIN { OFS = "\t" }
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "state_profile") column = i
              if (!column) { print "no state_profile column" >"/dev/stderr"; exit 1 } }
    NR > 1 && $1 == capability && $2 == platform { $column = value; edited++ }
    { print }
    END { if (!edited) { print "no row for " capability "/" platform >"/dev/stderr"; exit 1 } }' \
    "$repo_root/config/capabilities.tsv"
}

# A name no schema answers to would make doctor reject a state file every
# machine writes correctly, so it is caught here rather than on a machine.
new_scratch state-profile-unknown
sed -i 's/\tmacos-containers\tpodman-machine\t/\tmacos-containers\tnot-a-schema\t/' \
  "$scratch/config/capabilities.tsv"
expect_scratch_rejected 'a state_profile no schema declares is rejected' \
  "macos/containers: state_profile 'not-a-schema' is not a schema common/lib/profile-state.sh declares"

# One file has one schema. Two rows disagreeing about it would make doctor's
# verdict depend on which capability it reached first.
new_scratch state-profile-disagreement
set_state_profile backpass macos ocaml >"$scratch/config/capabilities.tsv"
expect_scratch_rejected 'two rows disagreeing about one state file are rejected' \
  "one state file has one schema"

# The file name and the schema move together: a row that names one without the
# other leaves doctor comparing a real state file against nothing.
new_scratch state-profile-missing
set_state_profile ocaml macos - >"$scratch/config/capabilities.tsv"
expect_scratch_rejected 'a state file with no declared schema is rejected' \
  "macos/ocaml: state 'ocaml' and state_profile '-' must either both be '-' or both name something"

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
        'NR > 1 && $2 == p && $11 == v && $16 == "implemented" { found = 1 }
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
awk -F '\t' '$2 == "windows" && $11 != "platforms/windows/verify.ps1" && $16 == "implemented" {
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
grep -Fq 'plasma9: a directory under platforms/ with no row in config/capabilities.tsv' \
  <<<"$unregistered" || {
  printf 'An unregistered platform directory was not reported:\n%s\n' "$unregistered" >&2
  exit 1
}
grep -Fq 'scripts/validate-capabilities.py PLATFORMS is' <<<"$unregistered" || {
  printf 'An unregistered platform was not reported against the validator list:\n%s\n' \
    "$unregistered" >&2
  exit 1
}
printf 'PASS: an unregistered platform directory is rejected\n'

# --- A package array is read whichever way it is declared -------------------

# The pattern was anchored on a line start and nothing else, so a declaration
# keyword hid the array behind it -- a shape this tree already writes at
# common/lib/verify.sh and common/lib/capabilities.sh. An installer could then
# install packages no row owns, and a verifier could keep the hardcoded list
# the rule above forbids, with the whole pipeline green.
new_scratch declared-installer-array
printf 'declare -a extra_packages=(unowned-pkg)\n' \
  >>"$scratch/platforms/fedora/scripts/install-kde-theme.sh"
expect_scratch_rejected 'a declare -a package array in an installer is rejected' \
  "platforms/fedora/scripts/install-kde-theme.sh: package array 'extra_packages' is not declared in ARRAY_OWNERS"

new_scratch readonly-installer-array
printf 'readonly more_packages=(unowned-pkg)\n' \
  >>"$scratch/platforms/fedora/scripts/install-kde-theme.sh"
expect_scratch_rejected 'a readonly package array in an installer is rejected' \
  "platforms/fedora/scripts/install-kde-theme.sh: package array 'more_packages' is not declared in ARRAY_OWNERS"

new_scratch local-verifier-array
printf 'check_own_packages() {\n  local -a packages=(ripgrep fd-find)\n  printf "%%s\\n" "${packages[@]}"\n}\n' \
  >>"$scratch/platforms/parrot-ctf/scripts/verify.sh"
expect_scratch_rejected 'a local -a package list in a verifier is rejected' \
  "platforms/parrot-ctf/scripts/verify.sh: verifier keeps its own packages=(...) list"

# An array shape the reader cannot read at all is an error rather than an
# invisible install: that is the difference between "this file installs
# nothing unowned" and "this file's installs were never compared".
new_scratch unreadable-array
printf 'mapfile -t hidden_packages < <(printf "%%s\\n" unowned-pkg)\nextra_packages+=("${hidden_packages[@]}")\n' \
  >>"$scratch/platforms/fedora/scripts/install-kde-theme.sh"
expect_scratch_rejected 'a package array the reader cannot parse is rejected' \
  "package arrays are opened and"

printf 'Capability manifest validation passed.\n'
