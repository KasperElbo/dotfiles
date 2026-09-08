#!/usr/bin/env bash

# Rootless Podman helpers shared by the containers profile's installer and
# verifier. Source common/lib/common.sh before this file.

# subid_entry_exists <file> <user>: true if <user> already owns a range in
# the given /etc/subuid or /etc/subgid file.
subid_entry_exists() {
  local file="$1"
  local user="$2"

  [[ -r "$file" ]] || return 1
  grep -q "^${user}:" "$file" 2>/dev/null
}

# next_free_subid_start <file>: smallest subuid/subgid start at or above
# 100000 (Fedora's own useradd default floor) that does not overlap any
# existing range in <file>.
next_free_subid_start() {
  local file="$1"
  local floor=100000
  local highest_end=$((floor - 1))
  local start count end

  if [[ -r "$file" ]]; then
    while IFS=: read -r _ start count; do
      [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
      end=$((start + count - 1))
      ((end > highest_end)) && highest_end=$end
    done <"$file"
  fi

  printf '%d\n' "$((highest_end + 1))"
}

# ensure_subid_range <file> <flag> <user>: allocates a 65536-wide range for
# <user> in <file> via 'usermod <flag> start-end user', but only if <user>
# does not already own a range. <flag> is --add-subuids or --add-subgids.
ensure_subid_range() {
  local file="$1"
  local flag="$2"
  local user="$3"
  local range_size=65536
  local start end

  if subid_entry_exists "$file" "$user"; then
    info "$user already has a $(basename "$file") range"
    return 1
  fi

  start="$(next_free_subid_start "$file")"
  end=$((start + range_size - 1))

  info "Allocating $(basename "$file") range $start-$end for $user"
  sudo usermod "$flag" "$start-$end" "$user" ||
    die "Failed to allocate $(basename "$file") range for $user"
  return 0
}

# ensure_subid_ranges <user> <subuid_file> <subgid_file>: allocates whichever
# of the subuid/subgid ranges <user> is missing, then migrates any existing
# rootless storage to the new mapping. Safe to rerun: a user who already has
# both ranges is left untouched.
ensure_subid_ranges() {
  local user="$1"
  local subuid_file="$2"
  local subgid_file="$3"
  local changed="false"

  ensure_subid_range "$subuid_file" --add-subuids "$user" && changed="true"
  ensure_subid_range "$subgid_file" --add-subgids "$user" && changed="true"

  if [[ "$changed" == "true" ]]; then
    info "Migrating existing rootless storage to the new subuid/subgid mapping"
    podman system migrate
  fi
}
