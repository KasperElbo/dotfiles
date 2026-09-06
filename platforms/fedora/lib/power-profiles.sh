#!/usr/bin/env bash

# Power-profile service helpers. Source common/lib/common.sh before this file.

conflicting_power_profile_units() {
  printf '%s\n' \
    power-profiles-daemon.service \
    tuned-ppd.service \
    tuned.service
}

power_profile_unit_state() {
  systemctl is-enabled "$1" 2>/dev/null || true
}

mask_conflicting_power_profile_services() {
  local state
  local unit

  while IFS= read -r unit; do
    state="$(power_profile_unit_state "$unit")"

    case "$state" in
    "" | not-found)
      continue
      ;;
    masked)
      if systemctl is-active --quiet "$unit"; then
        info "Stopping masked power-profile service: $unit"
        sudo systemctl stop "$unit"
      fi
      continue
      ;;
    esac

    info "Masking conflicting power-profile service: $unit"
    sudo systemctl mask --now "$unit"
  done < <(conflicting_power_profile_units)
}
