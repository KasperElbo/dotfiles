#!/usr/bin/env bash

# shellcheck source=profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/profile-state.sh"

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

install_lifecycle_begin() {
  local platform="$1" capabilities="$2" rerun="$3"
  local existing_state existing_status existing_platform existing_capabilities existing_revision
  INSTALL_LIFECYCLE_PLATFORM="$platform"
  INSTALL_LIFECYCLE_CAPABILITIES="$capabilities"
  INSTALL_LIFECYCLE_RERUN="$rerun"
  INSTALL_LIFECYCLE_STARTED_AT=""
  INSTALL_LIFECYCLE_FINISHED_AT=""
  existing_state="$(install_state_path)"
  if [[ -f "$existing_state" ]] && profile_state_validate_file "$existing_state" install >/dev/null 2>&1; then
    existing_status="$(profile_state_read "$existing_state" status install)"
    existing_platform="$(profile_state_read "$existing_state" platform install)"
    existing_capabilities="$(profile_state_read "$existing_state" observed_capabilities install)"
    existing_revision="$(profile_state_read "$existing_state" revision install)"
    if [[ "$existing_status" == installed && "$existing_platform" == "$platform" &&
      "$existing_capabilities" == "$capabilities" &&
      "$existing_revision" == "$(install_repository_revision)" ]]; then
      INSTALL_LIFECYCLE_STARTED_AT="$(profile_state_read "$existing_state" started_at install)"
      INSTALL_LIFECYCLE_FINISHED_AT="$(profile_state_read "$existing_state" finished_at install)"
    fi
  fi
  INSTALL_LIFECYCLE_STARTED_AT="${INSTALL_LIFECYCLE_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  DOTFILES_PLAN_LOG="$(profile_state_dir)/install.log"
  export INSTALL_LIFECYCLE_PLATFORM INSTALL_LIFECYCLE_CAPABILITIES
  export INSTALL_LIFECYCLE_RERUN INSTALL_LIFECYCLE_STARTED_AT INSTALL_LIFECYCLE_FINISHED_AT
  export DOTFILES_PLAN_LOG
  profile_state_write "$(install_state_path)" install applying \
    "platform=$platform" \
    "requested_capabilities=$capabilities" \
    observed_capabilities=pending \
    external_assurance=not-recorded \
    "repository=$(install_repository_url)" \
    "revision=$(install_repository_revision)" \
    "provenance=capability-manifest@$(install_repository_revision)" \
    "started_at=$INSTALL_LIFECYCLE_STARTED_AT" \
    "rerun=$rerun"
}

install_lifecycle_failed() {
  local failed_step="${1:-unknown}" completed="${2:-none}" pending="${3:-none}"
  [[ -n "${INSTALL_LIFECYCLE_PLATFORM:-}" ]] || return 0
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
    "pending_steps=$pending" "rerun=$INSTALL_LIFECYCLE_RERUN"
}

install_lifecycle_commit() {
  profile_state_write "$(install_state_path)" install installed \
    "platform=$INSTALL_LIFECYCLE_PLATFORM" \
    "requested_capabilities=$INSTALL_LIFECYCLE_CAPABILITIES" \
    "observed_capabilities=$INSTALL_LIFECYCLE_CAPABILITIES" \
    external_assurance=not-recorded \
    "repository=$(install_repository_url)" \
    "revision=$(install_repository_revision)" \
    "provenance=capability-manifest@$(install_repository_revision)" \
    "started_at=$INSTALL_LIFECYCLE_STARTED_AT" \
    "finished_at=${INSTALL_LIFECYCLE_FINISHED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    "rerun=$INSTALL_LIFECYCLE_RERUN"
}
