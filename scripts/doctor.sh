#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"

state="$(profile_state_dir)/install.conf"
failures=0
warnings=0
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }
warning() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; warnings=$((warnings + 1)); }

printf 'Dotfiles doctor (read-only)\n\n'
if [[ ! -e "$state" ]]; then
  warning "No lifecycle state found at $state (legacy or never installed)."
else
  if profile_state_validate_file "$state" install; then
    status="$(profile_state_read "$state" status install)"
    platform="$(profile_state_read "$state" platform install)"
    capabilities="$(profile_state_read "$state" requested_capabilities install)"
    revision="$(profile_state_read "$state" revision install)"
    [[ "$status" == installed ]] && pass "Last installation completed ($platform: $capabilities)." ||
      fail "Last installation is $status; rerun the recorded command after reviewing completed steps."
    current_revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf unknown)"
    [[ "$revision" == "$current_revision" ]] && pass "Checkout matches installed revision $revision." ||
      warning "Checkout revision $current_revision differs from installed revision $revision."

    IFS=, read -r -a selected <<<"$capabilities"
    for capability in "${selected[@]}"; do
      state_id="$(awk -F '\t' -v p="$platform" -v c="$capability" 'NR>1 && $1==c && $2==p && $15=="implemented" {print $12; exit}' "$repo_root/config/capabilities.tsv")"
      verifier="$(awk -F '\t' -v p="$platform" -v c="$capability" 'NR>1 && $1==c && $2==p && $15=="implemented" {print $11; exit}' "$repo_root/config/capabilities.tsv")"
      if [[ -n "$state_id" && "$state_id" != - && "$state_id" != install ]]; then
        component_state="$XDG_CONFIG_HOME/dotfiles/$state_id.conf"
        if [[ ! -e "$component_state" ]]; then
          fail "Enabled capability '$capability' is missing state: $component_state"
        else
          component_profile="$(awk -F= '$1 == "profile" {print $2; exit}' "$component_state")"
          if ! profile_state_validate_file "$component_state" "$component_profile"; then
            fail "Enabled capability '$capability' has corrupt state: $component_state"
          else
            component_status="$(profile_state_read "$component_state" status "$component_profile" 2>/dev/null || true)"
            if [[ -z "$component_status" ]]; then
              warning "Enabled capability '$capability' still uses legacy unversioned state."
            elif [[ "$component_status" != installed ]]; then
              fail "Enabled capability '$capability' state is $component_status, not installed."
            fi
          fi
        fi
      fi
      [[ -z "$verifier" || "$verifier" == none ]] || printf '  Verify %-16s %s\n' "$capability:" "$verifier"
    done

    while IFS= read -r state_id; do
      [[ -n "$state_id" && "$state_id" != - && "$state_id" != install ]] || continue
      component_state="$XDG_CONFIG_HOME/dotfiles/$state_id.conf"
      [[ -e "$component_state" ]] || continue
      state_is_selected=false
      for capability in "${selected[@]}"; do
        selected_state="$(awk -F '\t' -v p="$platform" -v c="$capability" 'NR>1 && $1==c && $2==p && $15=="implemented" {print $12; exit}' "$repo_root/config/capabilities.tsv")"
        [[ "$selected_state" != "$state_id" ]] || state_is_selected=true
      done
      [[ "$state_is_selected" == true ]] ||
        warning "Residual state is no longer owned by the installed selection: $component_state"
    done < <(awk -F '\t' -v p="$platform" 'NR>1 && $2==p && $15=="implemented" && $12!="-" {print $12}' "$repo_root/config/capabilities.tsv" | sort -u)
  else
    fail "Lifecycle state is corrupt or uses an unsupported schema: $state"
  fi
fi

printf '\nResult: %d failure(s), %d warning(s). No changes made.\n' "$failures" "$warnings"
((failures == 0))
