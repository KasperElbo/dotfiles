#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/validate-capabilities.py"
python3 "$repo_root/scripts/render-capability-matrix.py" --check

fixture="$(mktemp)"
trap 'rm -f -- "$fixture" "$fixture.log" "$fixture.provider" "$fixture.provider.log"' EXIT
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
[[ "$(grep -Fc '"$hardware_selected:hardware"' "$fedora_installer")" -ge 2 ]] || {
  printf 'Fedora hardware selection is not included in both preflight and lifecycle capability resolution.\n' >&2
  exit 1
}
grep -Fq 'DOTFILES_RERUN_COMMAND="$(build_rerun_command)"' "$fedora_installer"
grep -Fq 'args+=(--hardware "$hardware_model")' "$fedora_installer"
grep -Fq 'args+=(--secure-boot)' "$fedora_installer"
grep -Fq 'args+=(--charge-limit "$hardware_charge_limit")' "$fedora_installer"

hardware_dry_run="$(
  "$repo_root/install.sh" --dry-run --no-kde --no-latex \
    --hardware ga402xz --secure-boot --charge-limit 80
)"
[[ "$hardware_dry_run" == *'ASUS hardware:       ga402xz'* ]]
[[ "$hardware_dry_run" == *'Require Secure Boot: true'* ]]
[[ "$hardware_dry_run" == *'Battery limit:       80'* ]]

grep -Fq 'config/capabilities.tsv' "$repo_root/docs/capabilities.md"
printf 'Capability manifest validation passed.\n'