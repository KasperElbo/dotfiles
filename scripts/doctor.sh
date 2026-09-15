#!/usr/bin/env bash
set -euo pipefail

# The lifecycle health report behind ./doctor. It keeps its own pass, fail and
# warning helpers on purpose instead of sourcing common/lib/verify.sh:
#
#   - It reports lifecycle state (the installation record, component state
#     files, the remembered --rerun configuration), not capability state, and
#     is not named in the verifier column of config/capabilities.tsv. It points
#     at those verifiers instead of repeating them.
#   - It runs under errexit, where the library's fail(), which returns 1, would
#     end the report at its first finding instead of listing every one.
#   - Its closing "Result: N failure(s), M warning(s). No changes made." line
#     is its own contract (tests/test-doctor.sh), not finish_verification's.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"
# shellcheck source=../common/lib/install-lifecycle.sh
source "$repo_root/common/lib/install-lifecycle.sh"
# shellcheck source=../common/lib/capabilities.sh
source "$repo_root/common/lib/capabilities.sh"

state="$(profile_state_dir)/install.conf"

# A field of the recorded platform's implemented capability row, or nothing
# when the capability is absent or not implemented there.
implemented_capability_field() {
  manifest_values "$CAPABILITY_MANIFEST" "$2" \
    capability "$1" platform "$platform" status implemented
}

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
    if [[ "$status" == installed ]]; then
      pass "Last installation completed ($platform: $capabilities)."
    else
      # Name the step that stopped, and point at something that exists. The
      # record's own "rerun" key is display-only text that nothing executes,
      # and a failed run is never remembered, so telling the user to "rerun
      # the recorded command" named a path this repository does not have.
      failed_step="$(install_state_optional "$state" failed_step)"
      completed_steps="$(install_state_optional "$state" completed_steps)"
      pending_steps="$(install_state_optional "$state" pending_steps)"
      if [[ -n "$failed_step" ]]; then
        fail "Last installation is $status at step [$failed_step] ($platform)."
      else
        fail "Last installation is $status ($platform); it stopped before recording a failed step."
      fi
      [[ -z "$completed_steps" ]] || printf '  Completed steps: %s\n' "$completed_steps"
      [[ -z "$pending_steps" ]] || printf '  Pending steps:   %s\n' "$pending_steps"
      printf '  Completed component changes are not rolled back, and a failed run is never\n'
      printf '  remembered, so --rerun cannot reapply it. Either reapply this machine'"'"'s last\n'
      printf '  successful configuration (preview it with ./install.sh --rerun --dry-run), or\n'
      printf '  start a fresh ./install.sh with the options you want.\n'
    fi
    current_revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf unknown)"
    if [[ "$revision" == "$current_revision" ]]; then
      pass "Checkout matches installed revision $revision."
    else
      warning "Checkout revision $current_revision differs from installed revision $revision."
    fi

    IFS=, read -r -a selected <<<"$capabilities"
    for capability in "${selected[@]}"; do
      state_id="$(implemented_capability_field "$capability" state)"
      verifier="$(implemented_capability_field "$capability" verifier)"
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

    # Read before the loop, not in a process substitution, so a manifest that
    # cannot be read stops doctor instead of silently skipping this check.
    implemented_states="$(manifest_values "$CAPABILITY_MANIFEST" state \
      platform "$platform" status implemented)"
    while IFS= read -r state_id; do
      [[ -n "$state_id" && "$state_id" != - && "$state_id" != install ]] || continue
      component_state="$XDG_CONFIG_HOME/dotfiles/$state_id.conf"
      [[ -e "$component_state" ]] || continue
      state_is_selected=false
      for capability in "${selected[@]}"; do
        selected_state="$(implemented_capability_field "$capability" state)"
        [[ "$selected_state" != "$state_id" ]] || state_is_selected=true
      done
      [[ "$state_is_selected" == true ]] ||
        warning "Residual state is no longer owned by the installed selection: $component_state"
    done < <(sort -u <<<"$implemented_states")
  else
    fail "Lifecycle state is corrupt or uses an unsupported schema: $state"
  fi
fi

# Whether this machine can reapply its own configuration. The record itself
# stays out of the report: doctor says that a valid one exists and how to use
# it, and ./install.sh --rerun --dry-run shows the resolved detail.
printf '\n'
if install_remembered_load 2>/dev/null; then
  pass "Remembered configuration is available for --rerun ($INSTALL_REMEMBERED_PLATFORM, recorded $INSTALL_REMEMBERED_AT)."
  printf '  Reapply it with   ./install.sh --rerun\n'
  printf '  Preview it with   ./install.sh --rerun --dry-run\n'
else
  remembered_reason="$(install_remembered_load 2>&1 >/dev/null | head -n 1 || true)"
  warning "No configuration is available for ./install.sh --rerun: $remembered_reason"
fi

printf '\nResult: %d failure(s), %d warning(s). No changes made.\n' "$failures" "$warnings"
((failures == 0))
