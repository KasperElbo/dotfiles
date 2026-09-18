#!/usr/bin/env bash

# Versioned machine-local profile state. This file intentionally does not set
# shell options: sourcing a library must not alter its caller's policy.
#
# It needs atomic_write_file and die from lib/common.sh, and sources that
# itself, so it is correct sourced standalone.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

PROFILE_STATE_SCHEMA_VERSION=2

profile_state_allowed_keys() {
  case "$1" in
  # selection/selection_schema record the persistent configuration of the
  # run being applied; the last_successful_* keys record the newest
  # *completely successful* one and are what --rerun reapplies. Keeping
  # both in this one file is deliberate: a parallel "last command" store
  # could disagree with the lifecycle status it belongs to.
  install) printf '%s\n' platform requested_capabilities observed_capabilities external_assurance repository revision provenance started_at finished_at failed_step completed_steps pending_steps rerun selection selection_schema last_successful_selection last_successful_platform last_successful_at ;;
  # requested records the desired optional-component set; the per-component
  # keys record what was observed installed; the *_source/*_commit/*_digest
  # *_digest keys record the remote installer that ran; *_target_digest
  # records the installed binary, and is what proves ownership before a
  # removal. Those are different artifacts and must not be conflated.
  # *_target_path records where that binary actually landed, which is the
  # command path unless the upstream installed into its own directory and left
  # a launcher symlink; a removal deletes the recorded binary, not the link.
  # None of the new keys are required, so state written by an earlier
  # release stays readable and diagnosable instead of failing validation.
  ai) printf '%s\n' requested claude_code herdr codex firstmate firstmate_source firstmate_commit treehouse treehouse_source treehouse_digest treehouse_target_digest treehouse_target_path no_mistakes no_mistakes_source no_mistakes_digest no_mistakes_target_digest no_mistakes_target_path gh_axi chrome_devtools_axi lavish_axi tasks_axi quota_axi gnhf backpass acpx ;;
  ocaml) printf '%s\n' switch compiler ;;
  ga402xz | ga402rk) printf '%s\n' secure_boot charge_limit ;;
  containers) printf '%s\n' runtime mode compose_provider api_socket user ;;
  desktop-tools) printf '%s\n' image_viewer image_editor pdf_viewer pdf_tool archive_manager media_player scanner force_defaults ;;
  hardening) printf '%s\n' selinux_mode faillock sudo_logfile auditd sysctl_ptrace_scope sysctl_kptr_restrict sysctl_dmesg_restrict ssh dnf_automatic ;;
  tailscale) printf '%s\n' repo service variant ;;
  vm-guest) printf '%s\n' hypervisor guest_agent desktop_agent display network shared_folders ;;
  vm-host) printf '%s\n' backend libvirt_uri network network_mode storage_pool storage_path disk_format firmware display device_model guest_agent user ;;
  podman-machine) printf '%s\n' rootful ;;
  parrot-ctf) printf '%s\n' hypervisor network guest_agent display shared_folders host_secrets security_tools ;;
  *) return 1 ;;
  esac
}

profile_state_required_keys() {
  case "$1" in
  install) printf '%s\n' platform requested_capabilities observed_capabilities external_assurance repository revision provenance ;;
  ai) printf '%s\n' claude_code herdr codex firstmate ;;
  ocaml) printf '%s\n' switch compiler ;;
  ga402xz | ga402rk) printf '%s\n' secure_boot charge_limit ;;
  containers) printf '%s\n' runtime mode api_socket ;;
  desktop-tools) printf '%s\n' image_viewer image_editor pdf_viewer pdf_tool ;;
  hardening) printf '%s\n' selinux_mode faillock auditd ;;
  tailscale) printf '%s\n' variant ;;
  vm-guest) printf '%s\n' hypervisor guest_agent network ;;
  vm-host) printf '%s\n' backend libvirt_uri network storage_pool ;;
  podman-machine) printf '%s\n' rootful ;;
  parrot-ctf) printf '%s\n' hypervisor network host_secrets security_tools ;;
  *) return 1 ;;
  esac
}

profile_state_key_is_listed() {
  local key="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [[ "$candidate" != "$key" ]] || return 0
  done
  return 1
}

profile_state_validate_value() {
  local key="$1"
  local value="$2"
  [[ "$value" != *$'\n'* && "$value" != *'='* ]] || return 1
  [[ -n "$value" || "$key" == charge_limit ]] || return 1
  [[ -n "$value" ]] || return 0
  case "$key" in
  schema_version) [[ "$value" == "$PROFILE_STATE_SCHEMA_VERSION" ]] ;;
  status) [[ "$value" == applying || "$value" == installed || "$value" == failed ]] ;;
  rootful | force_defaults) [[ "$value" == true || "$value" == false ]] ;;
  secure_boot | api_socket) [[ "$value" == enabled || "$value" == disabled || "$value" == required || "$value" == not-required || "$value" == true || "$value" == false ]] ;;
  # The checkout's git remote, recorded verbatim. Real remotes use characters
  # the narrow charset below rejects (git@host:~user/repo.git), and the only
  # bytes that break this file format, a newline or '=', were refused above.
  repository) return 0 ;;
  *) [[ "$value" =~ ^[[:alnum:]._/@:+,\ -]+$ ]] ;;
  esac
}

profile_state_validate_file() {
  local path="$1"
  local expected_profile="${2:-}"
  local line key value profile="" schema="" status="" allowed_output required_output
  local seen_count=0
  local -a seen=() allowed=() required=()

  [[ -r "$path" ]] || { printf 'State file is not readable: %s\n' "$path" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[a-z][a-z0-9_]*=.*$ ]] || {
      printf 'Invalid state line in %s: %s\n' "$path" "$line" >&2
      return 1
    }
    key="${line%%=*}"
    value="${line#*=}"
    if ((seen_count > 0)) && profile_state_key_is_listed "$key" "${seen[@]}"; then
      printf 'Duplicate state key in %s: %s\n' "$path" "$key" >&2
      return 1
    fi
    seen+=("$key")
    seen_count=$((seen_count + 1))
    profile_state_validate_value "$key" "$value" || {
      printf 'Invalid value for %s in %s\n' "$key" "$path" >&2
      return 1
    }
    [[ "$key" != profile ]] || profile="$value"
    [[ "$key" != schema_version ]] || schema="$value"
    [[ "$key" != status ]] || status="$value"
  done <"$path"

  [[ -n "$profile" ]] || { printf 'Missing state key in %s: profile\n' "$path" >&2; return 1; }
  [[ -z "$expected_profile" || "$profile" == "$expected_profile" ]] || {
    printf 'Unexpected profile in %s: %s\n' "$path" "$profile" >&2; return 1;
  }

  # Schema 1 is the historical unversioned key=value format. Readers accept it
  # so old installations remain diagnosable; writers always migrate to v2.
  [[ -n "$schema" ]] || schema=1
  [[ "$schema" == 1 || "$schema" == "$PROFILE_STATE_SCHEMA_VERSION" ]] || {
    printf 'Unsupported state schema in %s: %s\n' "$path" "$schema" >&2; return 1;
  }
  [[ "$schema" != "$PROFILE_STATE_SCHEMA_VERSION" || -n "$status" ]] || {
    printf 'Missing state key in %s: status\n' "$path" >&2; return 1;
  }

  allowed_output="$(profile_state_allowed_keys "$profile")" || {
    printf 'Unknown state profile in %s: %s\n' "$path" "$profile" >&2; return 1;
  }
  while IFS= read -r key; do allowed+=("$key"); done <<<"$allowed_output"
  allowed+=(schema_version profile status)
  for key in "${seen[@]}"; do
    profile_state_key_is_listed "$key" "${allowed[@]}" || {
      printf 'Unknown state key in %s: %s\n' "$path" "$key" >&2; return 1;
    }
  done
  required_output="$(profile_state_required_keys "$profile")" || {
    printf 'Unknown state profile in %s: %s\n' "$path" "$profile" >&2; return 1;
  }
  while IFS= read -r key; do required+=("$key"); done <<<"$required_output"
  required+=(profile)
  [[ "$schema" != "$PROFILE_STATE_SCHEMA_VERSION" ]] || required+=(schema_version status)
  for key in "${required[@]}"; do
    profile_state_key_is_listed "$key" "${seen[@]}" || {
      printf 'Missing state key in %s: %s\n' "$path" "$key" >&2; return 1;
    }
  done
}

profile_state_read() {
  local path="$1" key="$2" expected_profile="${3:-}"
  profile_state_validate_file "$path" "$expected_profile" || return 1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length(wanted) + 2); found=1 } END { exit !found }' "$path"
}

profile_state_write() {
  local path="$1" profile="$2" status="$3"
  shift 3
  local entry key value allowed_output
  local -a keys=(schema_version profile status) allowed=()

  # Read the key list once, in this shell. Membership is decided by the same
  # helper the file validator uses: piping the list into a reader that stops at
  # the first match leaves the writer to be killed by SIGPIPE, which under the
  # callers' pipefail rejected a key the list contains.
  allowed_output="$(profile_state_allowed_keys "$profile")" || die "Unknown state profile: $profile"
  while IFS= read -r key; do allowed+=("$key"); done <<<"$allowed_output"
  profile_state_validate_value status "$status" || die "Invalid profile state status: $status"
  for entry in "$@"; do
    [[ "$entry" == *=* ]] || die "Invalid state entry: $entry"
    key="${entry%%=*}"; value="${entry#*=}"
    profile_state_key_is_listed "$key" "${keys[@]}" && die "Duplicate state key: $key"
    profile_state_key_is_listed "$key" "${allowed[@]}" || die "Unknown state key for $profile: $key"
    profile_state_validate_value "$key" "$value" || die "Invalid state value for $key"
    keys+=("$key")
  done

  {
    printf 'schema_version=%s\nprofile=%s\nstatus=%s\n' "$PROFILE_STATE_SCHEMA_VERSION" "$profile" "$status"
    printf '%s\n' "$@"
  } | atomic_write_file "$path"
  profile_state_validate_file "$path" "$profile"
}

profile_state_write_content() {
  local path="$1" expected_profile="$2" status="${3:-installed}"
  local line key profile=""
  local entries_count=0
  local -a entries=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || die "Invalid state entry: $line"
    key="${line%%=*}"
    if [[ "$key" == profile ]]; then
      profile="${line#*=}"
    else
      entries+=("$line")
      entries_count=$((entries_count + 1))
    fi
  done
  [[ "$profile" == "$expected_profile" ]] ||
    die "State content profile mismatch: expected $expected_profile, found ${profile:-empty}"
  if ((entries_count > 0)); then
    profile_state_write "$path" "$profile" "$status" "${entries[@]}"
  else
    profile_state_write "$path" "$profile" "$status"
  fi
}

profile_state_set_status() {
  local path="$1" expected_profile="$2" new_status="$3"
  local line key
  local entries_count=0
  local -a entries=()
  profile_state_validate_file "$path" "$expected_profile" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    key="${line%%=*}"
    case "$key" in
    schema_version | profile | status) ;;
    *) entries+=("$line"); entries_count=$((entries_count + 1)) ;;
    esac
  done <"$path"
  if ((entries_count > 0)); then
    profile_state_write "$path" "$expected_profile" "$new_status" "${entries[@]}"
  else
    profile_state_write "$path" "$expected_profile" "$new_status"
  fi
}

profile_state_dir() {
  printf '%s/dotfiles\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}
