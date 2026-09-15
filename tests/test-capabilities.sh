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
printf 'Capability manifest validation passed.\n'
