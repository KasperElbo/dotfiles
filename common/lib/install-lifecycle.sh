#!/usr/bin/env bash

# shellcheck source=profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/profile-state.sh"
# shellcheck source=install-selection.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-selection.sh"

install_state_path() {
  printf '%s/install.conf\n' "$(profile_state_dir)"
}

install_repository_url() {
  git -C "$DOTFILES_ROOT" config --get remote.origin.url 2>/dev/null ||
    printf 'local-checkout\n'
}

install_repository_revision() {
  git -C "$DOTFILES_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown\n'
}

# Read an optional key without letting a missing key fail an errexit caller.
install_state_optional() {
  local path="$1" key="$2"
  [[ -f "$path" ]] || return 0
  profile_state_read "$path" "$key" install 2>/dev/null || true
}

# --- Last-known-good rerun target -------------------------------------------
#
# The "selection" key is the configuration of the run being applied, kept for
# diagnostics. The last_successful_* keys are the authoritative --rerun target
# and are replaced only by install_lifecycle_commit, so a dry run, a failed
# preflight, a cancelled confirmation, a failed step and a failed verifier all
# leave the previous successful configuration in place. Every state write goes
# through profile_state_write, which renames a complete temporary file into
# place, so the invariant survives an interrupted write too.
#
# selection_schema describes the encoding of last_successful_selection only. It
# is carried forward verbatim with that record, so a checkout that predates a
# future encoding never mislabels a record it did not write.

install_lifecycle_carry_forward_entries() {
  local path selection platform recorded_at schema
  path="$(install_state_path)"
  [[ -f "$path" ]] || return 0
  profile_state_validate_file "$path" install >/dev/null 2>&1 || return 0
  selection="$(install_state_optional "$path" last_successful_selection)"
  [[ -n "$selection" ]] || return 0
  platform="$(install_state_optional "$path" last_successful_platform)"
  recorded_at="$(install_state_optional "$path" last_successful_at)"
  schema="$(install_state_optional "$path" selection_schema)"
  printf '%s\n' "last_successful_selection=$selection"
  [[ -z "$platform" ]] || printf '%s\n' "last_successful_platform=$platform"
  [[ -z "$recorded_at" ]] || printf '%s\n' "last_successful_at=$recorded_at"
  [[ -z "$schema" ]] || printf '%s\n' "selection_schema=$schema"
}

install_lifecycle_begin() {
  local platform="$1" capabilities="$2" rerun="$3" selection="${4:-}"
  local existing_state existing_status existing_platform existing_capabilities
  local existing_revision existing_selection entry
  local -a entries=()
  INSTALL_LIFECYCLE_PLATFORM="$platform"
  INSTALL_LIFECYCLE_CAPABILITIES="$capabilities"
  INSTALL_LIFECYCLE_RERUN="$rerun"
  INSTALL_LIFECYCLE_SELECTION="$selection"
  INSTALL_LIFECYCLE_STARTED_AT=""
  INSTALL_LIFECYCLE_FINISHED_AT=""
  existing_state="$(install_state_path)"
  if [[ -f "$existing_state" ]] && profile_state_validate_file "$existing_state" install >/dev/null 2>&1; then
    existing_status="$(profile_state_read "$existing_state" status install)"
    existing_platform="$(profile_state_read "$existing_state" platform install)"
    existing_capabilities="$(profile_state_read "$existing_state" observed_capabilities install)"
    existing_revision="$(profile_state_read "$existing_state" revision install)"
    existing_selection="$(install_state_optional "$existing_state" selection)"
    if [[ "$existing_status" == installed && "$existing_platform" == "$platform" &&
      "$existing_capabilities" == "$capabilities" &&
      "$existing_selection" == "$selection" &&
      "$existing_revision" == "$(install_repository_revision)" ]]; then
      INSTALL_LIFECYCLE_STARTED_AT="$(profile_state_read "$existing_state" started_at install)"
      INSTALL_LIFECYCLE_FINISHED_AT="$(profile_state_read "$existing_state" finished_at install)"
    fi
  fi
  INSTALL_LIFECYCLE_STARTED_AT="${INSTALL_LIFECYCLE_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  DOTFILES_PLAN_LOG="$(profile_state_dir)/install.log"
  export INSTALL_LIFECYCLE_PLATFORM INSTALL_LIFECYCLE_CAPABILITIES
  export INSTALL_LIFECYCLE_RERUN INSTALL_LIFECYCLE_SELECTION
  export INSTALL_LIFECYCLE_STARTED_AT INSTALL_LIFECYCLE_FINISHED_AT
  export DOTFILES_PLAN_LOG
  while IFS= read -r entry; do entries+=("$entry"); done < <(install_lifecycle_carry_forward_entries)
  [[ -z "$selection" ]] || entries+=("selection=$selection")
  profile_state_write "$(install_state_path)" install applying \
    "platform=$platform" \
    "requested_capabilities=$capabilities" \
    observed_capabilities=pending \
    external_assurance=not-recorded \
    "repository=$(install_repository_url)" \
    "revision=$(install_repository_revision)" \
    "provenance=capability-manifest@$(install_repository_revision)" \
    "started_at=$INSTALL_LIFECYCLE_STARTED_AT" \
    "rerun=$rerun" "${entries[@]}"
}

install_lifecycle_failed() {
  local failed_step="${1:-unknown}" completed="${2:-none}" pending="${3:-none}" entry
  local -a entries=()
  [[ -n "${INSTALL_LIFECYCLE_PLATFORM:-}" ]] || return 0
  while IFS= read -r entry; do entries+=("$entry"); done < <(install_lifecycle_carry_forward_entries)
  [[ -z "${INSTALL_LIFECYCLE_SELECTION:-}" ]] ||
    entries+=("selection=$INSTALL_LIFECYCLE_SELECTION")
  profile_state_write "$(install_state_path)" install failed \
    "platform=$INSTALL_LIFECYCLE_PLATFORM" \
    "requested_capabilities=$INSTALL_LIFECYCLE_CAPABILITIES" \
    observed_capabilities=partial \
    external_assurance=not-recorded \
    "repository=$(install_repository_url)" \
    "revision=$(install_repository_revision)" \
    "provenance=capability-manifest@$(install_repository_revision)" \
    "started_at=$INSTALL_LIFECYCLE_STARTED_AT" \
    "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "failed_step=$failed_step" "completed_steps=$completed" \
    "pending_steps=$pending" "rerun=$INSTALL_LIFECYCLE_RERUN" "${entries[@]}"
}

install_lifecycle_commit() {
  local finished_at entry
  local -a entries=()
  finished_at="${INSTALL_LIFECYCLE_FINISHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  if [[ -n "${INSTALL_LIFECYCLE_SELECTION:-}" ]]; then
    # A complete success is the only thing that may replace the rerun target.
    entries+=("selection=$INSTALL_LIFECYCLE_SELECTION")
    entries+=("last_successful_selection=$INSTALL_LIFECYCLE_SELECTION")
    entries+=("last_successful_platform=$INSTALL_LIFECYCLE_PLATFORM")
    entries+=("last_successful_at=$finished_at")
    entries+=("selection_schema=$INSTALL_SELECTION_SCHEMA_VERSION")
  else
    while IFS= read -r entry; do entries+=("$entry"); done < <(install_lifecycle_carry_forward_entries)
  fi
  profile_state_write "$(install_state_path)" install installed \
    "platform=$INSTALL_LIFECYCLE_PLATFORM" \
    "requested_capabilities=$INSTALL_LIFECYCLE_CAPABILITIES" \
    "observed_capabilities=$INSTALL_LIFECYCLE_CAPABILITIES" \
    external_assurance=not-recorded \
    "repository=$(install_repository_url)" \
    "revision=$(install_repository_revision)" \
    "provenance=capability-manifest@$(install_repository_revision)" \
    "started_at=$INSTALL_LIFECYCLE_STARTED_AT" \
    "finished_at=$finished_at" \
    "rerun=$INSTALL_LIFECYCLE_RERUN" "${entries[@]}"
}

install_lifecycle_rerun_hint() {
  printf '\nReapply this machine'"'"'s last successful configuration with:\n'
  printf '  ./install.sh --rerun\n'
}

# --- Reading the remembered configuration ------------------------------------
#
# Consumers (the --rerun entry point and doctor) get the validated rerun target
# or a focused diagnostic; nobody parses the state file by hand, and the
# human-readable "rerun" command is only ever displayed, never executed.

INSTALL_REMEMBERED_PLATFORM=""
INSTALL_REMEMBERED_SELECTION=""
INSTALL_REMEMBERED_AT=""

install_remembered_load() {
  local path status selection platform recorded_at schema recorded_command detail
  path="$(install_state_path)"
  INSTALL_REMEMBERED_PLATFORM=""
  INSTALL_REMEMBERED_SELECTION=""
  INSTALL_REMEMBERED_AT=""

  if [[ ! -e "$path" ]]; then
    printf 'No installation has been recorded on this machine: %s does not exist.\n' "$path" >&2
    printf 'Run ./install.sh with the options you want once; --rerun reapplies that configuration afterwards.\n' >&2
    return 1
  fi
  if ! detail="$(profile_state_validate_file "$path" install 2>&1 >/dev/null)"; then
    printf 'Lifecycle state is corrupt or uses an unsupported schema: %s\n' "$path" >&2
    [[ -z "$detail" ]] || printf '%s\n' "$detail" >&2
    printf 'Refusing to reapply a configuration this checkout cannot read. Inspect it with ./install.sh doctor.\n' >&2
    return 1
  fi

  status="$(profile_state_read "$path" status install)"
  selection="$(install_state_optional "$path" last_successful_selection)"
  if [[ -z "$selection" ]]; then
    if [[ "$status" == installed ]]; then
      printf 'The recorded installation predates --rerun support: %s has no remembered configuration.\n' "$path" >&2
      recorded_command="$(install_state_optional "$path" rerun)"
      [[ -z "$recorded_command" ]] ||
        printf 'Its recorded rerun guidance, for reference only (never executed): %s\n' "$recorded_command" >&2
      printf 'Run ./install.sh once with the options you want; that install records the structured configuration --rerun needs.\n' >&2
    else
      printf 'No successful installation is recorded on this machine; the last attempt is "%s".\n' "$status" >&2
      printf 'Complete an installation once; --rerun only reapplies a configuration that installed successfully.\n' >&2
    fi
    return 1
  fi

  schema="$(install_state_optional "$path" selection_schema)"
  if [[ "$schema" != "$INSTALL_SELECTION_SCHEMA_VERSION" ]]; then
    printf 'Remembered configuration uses selection schema "%s"; this checkout supports %s.\n' \
      "${schema:-missing}" "$INSTALL_SELECTION_SCHEMA_VERSION" >&2
    printf 'Update the checkout, or run ./install.sh once with the options you want to record a supported configuration.\n' >&2
    return 1
  fi

  platform="$(install_state_optional "$path" last_successful_platform)"
  if [[ -z "$platform" ]]; then
    printf 'Remembered configuration in %s records no platform; refusing to guess one.\n' "$path" >&2
    return 1
  fi
  recorded_at="$(install_state_optional "$path" last_successful_at)"

  # The function's results, read by the --rerun entry point and by doctor.
  # shellcheck disable=SC2034
  INSTALL_REMEMBERED_PLATFORM="$platform"
  # shellcheck disable=SC2034
  INSTALL_REMEMBERED_SELECTION="$selection"
  # shellcheck disable=SC2034
  INSTALL_REMEMBERED_AT="${recorded_at:-unknown}"
}

# ---------------------------------------------------------------------------
# Resolved selection
#
# The install state records two capability sets: what the run was asked for and
# what it finished. A verifier must consult the authoritative one for the run it
# is describing, so that the same check works during an install (status
# applying, observed still pending) and long after it (status installed).
# ---------------------------------------------------------------------------

install_lifecycle_resolved_capabilities() {
  local path observed requested
  path="$(install_state_path)"
  [[ -f "$path" ]] || return 1
  profile_state_validate_file "$path" install >/dev/null 2>&1 || return 1
  observed="$(profile_state_read "$path" observed_capabilities install 2>/dev/null || true)"
  requested="$(profile_state_read "$path" requested_capabilities install 2>/dev/null || true)"
  case "$observed" in
  pending | partial | '') printf '%s\n' "$requested" ;;
  *) printf '%s\n' "$observed" ;;
  esac
}

# 0 selected, 1 not selected, 2 no readable install state. The third answer is
# deliberately distinct: "this machine never recorded an installation" is not
# the same claim as "this capability was not chosen".
install_lifecycle_capability_selected() {
  local wanted="$1" capabilities entry
  local -a entries=()

  capabilities="$(install_lifecycle_resolved_capabilities)" || return 2
  IFS=, read -r -a entries <<<"$capabilities"
  for entry in ${entries[@]+"${entries[@]}"}; do
    [[ "$entry" != "$wanted" ]] || return 0
  done
  return 1
}

install_lifecycle_platform() {
  local path
  path="$(install_state_path)"
  [[ -f "$path" ]] || return 1
  profile_state_read "$path" platform install 2>/dev/null
}
