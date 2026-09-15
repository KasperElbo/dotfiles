#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/validate-capabilities.py"
python3 "$repo_root/scripts/render-capability-matrix.py" --check

fixture="$(mktemp)"
trap 'rm -f -- "$fixture" "$fixture".*' EXIT
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
[[ "$(grep -Fc "\"\$hardware_selected:hardware\"" "$fedora_installer")" -ge 2 ]] || {
  printf 'Fedora hardware selection is not included in both preflight and lifecycle capability resolution.\n' >&2
  exit 1
}
grep -Fq "DOTFILES_RERUN_COMMAND=\"\$(build_rerun_command)\"" "$fedora_installer"
grep -Fq "args+=(--hardware \"\$hardware_model\")" "$fedora_installer"
grep -Fq 'args+=(--secure-boot)' "$fedora_installer"
grep -Fq "args+=(--charge-limit \"\$hardware_charge_limit\")" "$fedora_installer"

hardware_dry_run="$(
  "$repo_root/install.sh" --dry-run --no-kde --no-latex \
    --hardware ga402xz --secure-boot --charge-limit 80
)"
[[ "$hardware_dry_run" == *'ASUS hardware:       ga402xz'* ]]
[[ "$hardware_dry_run" == *'Require Secure Boot: true'* ]]
[[ "$hardware_dry_run" == *'Battery limit:       80'* ]]

grep -Fq 'config/capabilities.tsv' "$repo_root/docs/capabilities.md"

# The supported platform list is derived from this manifest, not repeated in
# each generator. Adding a base row must reach the generated pages, and a
# platform without a human-authored title must stop the render rather than
# produce an unlabelled column.
manifest_platforms="$(awk -F '\t' 'NR > 1 && $1 == "base" && $15 == "implemented" {print $2}' \
  "$repo_root/config/capabilities.tsv")"
helper_platforms="$(PYTHONPATH="$repo_root/scripts/lib" python3 -c \
  'import manifests; print("\n".join(manifests.supported_platforms()))')"
[[ "$manifest_platforms" == "$helper_platforms" ]] || {
  printf 'The shared platform helper disagrees with the manifest.\n' >&2
  exit 1
}

cp "$repo_root/config/capabilities.tsv" "$fixture.platform"
printf 'base\tplasma9\tworkstation\t-\tenabled\t-\t-\tdnf\t-\t-\tplatforms/fedora/scripts/verify.sh\t-\tdocs/platforms/fedora.md\tnative\timplemented\n' \
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

printf 'Capability manifest validation passed.\n'
