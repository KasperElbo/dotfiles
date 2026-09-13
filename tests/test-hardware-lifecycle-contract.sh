#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/platforms/fedora/install.sh"
manifest="$repo_root/config/capabilities.tsv"

hardware_dry_run="$(
  "$repo_root/install.sh" --dry-run --no-kde --no-latex \
    --hardware ga402xz --secure-boot --charge-limit 80
)"
[[ "$hardware_dry_run" == *'ASUS hardware:       ga402xz'* ]]
[[ "$hardware_dry_run" == *'Require Secure Boot: true'* ]]
[[ "$hardware_dry_run" == *'Battery limit:       80'* ]]

# Hardware must participate in both capability preflight and lifecycle state.
[[ "$(grep -Fc '"$hardware_selected:hardware"' "$installer")" -ge 2 ]]
grep -Fq 'DOTFILES_RERUN_COMMAND="$(build_rerun_command)"' "$installer"
grep -Fq 'args+=(--hardware "$hardware_model")' "$installer"
grep -Fq 'args+=(--secure-boot)' "$installer"
grep -Fq 'args+=(--charge-limit "$hardware_charge_limit")' "$installer"

# Rerun guidance is expected to preserve every selected Fedora profile, not
# silently collapse back to the default installation.
for flag in \
  --kde --no-kde --latex --no-latex --ocaml --sway --vm-host --vm-guest \
  --hardening --desktop-tools --desktop-tools-force-defaults --containers \
  --containers-api-socket --tailscale --ai --codex --firstmate --gnhf \
  --backpass --hardware --secure-boot --charge-limit --non-interactive; do
  grep -Fq -- "$flag" "$installer"
done

hardware_packages="$(awk -F '\t' '$1=="hardware" && $2=="fedora" {print $9; exit}' "$manifest")"
[[ ",$hardware_packages," != *,supergfxctl,* ]]

printf 'Fedora hardware lifecycle and rerun contract tests passed.\n'