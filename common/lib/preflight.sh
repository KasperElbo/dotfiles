#!/usr/bin/env bash

# Pre-mutation checks shared by the platform installers and the Stow scripts.
#
# Each check prints a specific message to stderr and returns 1, so a preflight
# function under errexit refuses at the first failure, before anything changes.
# This library deliberately does not select shell options. It needs
# DOTFILES_ROOT and command_exists from lib/common.sh and the command-provider
# reader from lib/capabilities.sh, and sources both itself, so it is correct
# however the caller was set up.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
# shellcheck source=capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/capabilities.sh"
# shellcheck source=fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/fetch.sh"
# shellcheck source=network-sources.sh
source "$(dirname "${BASH_SOURCE[0]}")/network-sources.sh"

# preflight_xdg_layout
#
# Refuse an XDG root this repository does not deploy to, before anything is
# mutated.
#
# Stow is given one target, $HOME, so a package's `.config` tree is linked to
# $HOME/.config and its `.local/share` tree to $HOME/.local/share, whatever
# XDG_CONFIG_HOME and XDG_DATA_HOME say. Almost everything that later reads
# those files resolves them through the variables instead, so a nondefault root
# makes Stow succeed and the runtime and the verifier look somewhere the links
# are not. The data root disagrees with itself as well: the Fedora and macOS
# verifiers check $XDG_DATA_HOME/wallpapers while the code that sets the
# wallpaper builds $HOME/.local/share/wallpapers.
#
# Supporting a split layout would mean a second Stow target in all five Stow
# entry points, conflict detection against both, and a runtime that agrees;
# refusing it is the honest contract for a repository that deploys to $HOME,
# and it is refused here rather than discovered as a broken shell after an
# install that reported success. XDG_STATE_HOME is not checked: nothing is
# stowed under `.local/state`, and everything this repository writes there it
# also reads back through the variable.
# preflight_same_directory <a> <b>: whether two paths name the same directory
# by spelling alone. Repeated and trailing separators are noise -- $HOME/.config,
# $HOME/.config/ and $HOME//.config are one directory -- and both sides are
# normalized the same way, so the comparison is about the path and not about
# how it was typed. Lexical on purpose: the target need not exist yet.
preflight_same_directory() {
  local a b
  a="$(printf '%s' "$1" | tr -s '/')"
  b="$(printf '%s' "$2" | tr -s '/')"
  [[ "${a%/}" == "${b%/}" ]]
}

preflight_xdg_layout() {
  local violations=0 name value expected

  for name in XDG_CONFIG_HOME XDG_DATA_HOME; do
    case "$name" in
    XDG_CONFIG_HOME) expected="$HOME/.config" ;;
    XDG_DATA_HOME) expected="$HOME/.local/share" ;;
    esac
    value="${!name:-$expected}"
    if ! preflight_same_directory "$value" "$expected"; then
      printf '%s is %s, but this repository deploys to %s.\n' \
        "$name" "$value" "$expected" >&2
      violations=$((violations + 1))
    fi
  done

  if ((violations > 0)); then
    printf 'Stow links into $HOME while the shell, the installers and the verifiers read the XDG variables, so a separate root would leave configuration where nothing looks for it. Unset the variable (or set it to the path above) and run this again; nothing has been changed.\n' >&2
    return 1
  fi
}

preflight_writable_path() {
  local path="$1"
  local probe="$path"
  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  [[ -w "$probe" ]] || { printf 'Path is not writable: %s\n' "$path" >&2; return 1; }
}

# Free space below which an installation refuses to start. The user figure
# covers the mise runtimes, the Mason inventory and the LazyVim plugin set that
# every platform installs under XDG_DATA_HOME; the system figure covers one
# package-manager transaction and its download cache, and each platform names
# the path its own package manager writes to so a separate /var is measured
# rather than a roomy /. Both are floors for "certainly not enough", not an
# estimate of a full installation.
# Shared library values consumed by the platform installers.
# shellcheck disable=SC2034
PREFLIGHT_USER_DATA_MIN_MB=3072
# shellcheck disable=SC2034
PREFLIGHT_SYSTEM_MIN_MB=2048

# preflight_disk_space <path> <minimum-mb>
#
# Refuse when the filesystem holding <path> has less than <minimum-mb> free.
# The path itself need not exist yet; the nearest existing ancestor is the one
# that answers, because that is the filesystem the new directory lands on.
# Free space is read in KiB: -P -k is the one block size POSIX fixes for both
# GNU and BSD/Apple df, and BLOCKSIZE from the environment cannot change it.
preflight_disk_space() {
  local path="$1" minimum="$2"
  local probe="$path" available

  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  available="$(df -Pk -- "$probe" 2>/dev/null | awk 'NR == 2 { print $4 }')" ||
    available=""
  [[ "$available" =~ ^[0-9]+$ ]] || {
    printf 'Could not determine the free disk space for: %s\n' "$path" >&2
    return 1
  }
  available=$((available / 1024))
  ((available >= minimum)) || {
    printf 'Not enough free disk space for %s: %s MiB available, %s MiB required\n' \
      "$path" "$available" "$minimum" >&2
    return 1
  }
}

# preflight_network <url> [label]
#
# Refuse when a host this run will certainly download from cannot be reached.
# The check is connect-level (see fetch_host_reachable) and bounded by a short
# timeout. Platforms call it only for a fetch the run is certain to make, so a
# machine whose plan needs nothing from the network still installs offline.
preflight_network() {
  local url="$1"
  local label="${2:-$url}"

  # The URL is the caller's; the call site names the registered source.
  # network-source: caller-provided
  fetch_host_reachable "$url" || {
    printf 'Cannot reach %s, which this installation downloads from: %s\n' \
      "$label" "$url" >&2
    return 1
  }
}

# preflight_plan_network
#
# Refuse when a host the resolved plan will certainly download from cannot be
# reached. The repository scripts the plan runs are read from stdin, one per
# line, which is what `plan_scripts | preflight_plan_network` supplies; the
# hosts come from config/network-sources.tsv. Taking them on stdin is what
# keeps this library independent of the execution plan.
#
# The scoping RA-33 established still holds, and is now derived rather than
# hand-written: a plan with no networked step contributes no scripts, matches
# no registry row and probes nothing, so a machine whose plan needs nothing
# from the network still installs offline.
#
# Every unreachable host is named, not just the first: a machine with no route
# at all should be told once what it cannot reach, rather than one host per run.
preflight_plan_network() {
  local specs host components failed=0 probed=0

  # A checked substitution, not `< <(...)`: a registry that cannot be read
  # must stop the run, not silently probe nothing and report success.
  specs="$(network_sources_hosts)" || return 1
  [[ -n "$specs" ]] || return 0

  while IFS=$'\t' read -r host components; do
    [[ -n "$host" ]] || continue
    probed=$((probed + 1))
    # Every host is a registered row's own; its source is the row itself.
    # network-source: caller-provided
    fetch_host_reachable "https://$host" || {
      printf 'Cannot reach %s, which this installation downloads from: %s\n' \
        "$host" "$components" >&2
      failed=1
    }
  done <<<"$specs"

  ((failed == 0)) || {
    printf 'Nothing has been changed. Restore network access, or rerun without the steps that need it.\n' >&2
    return 1
  }
  info "Reachable: every host this run downloads from ($probed)."
}

preflight_platform_command_providers() {
  local platform="$1"
  local command provider classification missing=0
  local command_specs

  command_specs="$(capability_preflight_command_specs "$platform")" || return 1
  # Fail closed: an empty specification means the platform key does not match
  # the manifest, which would silently skip every pre-mutation check.
  [[ -n "$command_specs" ]] || {
    printf 'No preflight command specification for platform: %s\n' "$platform" >&2
    return 1
  }
  while IFS=$'\t' read -r command provider classification; do
    command_exists "$command" || {
      printf 'Missing %s command: %s (provider: %s)\n' \
        "$classification" "$command" "$provider" >&2
      missing=1
    }
  done <<<"$command_specs"

  ((missing == 0))
}

# preflight_stow_packages [--replaces <target>]... <package-root>::<package>...
#
# Refuse when any path a package would link is already taken. A --replaces
# target is a link the caller removes itself before stowing, such as one an
# earlier layout of this checkout left behind, and is not a conflict.
preflight_stow_packages() {
  local spec package_root package source relative target resolved parent conflict_type
  local candidate is_replaced canonical_root source_resolved
  local conflict_count=0
  local -a replaces=()
  # Physical, because a resolved symlink target is physical. DOTFILES_ROOT is
  # logical, so under a checkout reached through a symlink the prefix test
  # below would never match and every correctly stowed link would be reported
  # as owned by another checkout.
  canonical_root="$(resolve_existing_path "$DOTFILES_ROOT" 2>/dev/null || printf '%s' "$DOTFILES_ROOT")"
  canonical_root="${canonical_root%/}"
  while [[ "${1:-}" == --replaces ]]; do
    replaces+=("$2")
    shift 2
  done
  for spec in "$@"; do
    package_root="${spec%%::*}"; package="${spec#*::}"
    [[ -d "$package_root/$package" ]] || {
      printf 'Stow package is missing: %s (%s)\n' "$package" "$package_root" >&2
      conflict_count=$((conflict_count + 1)); continue
    }
    while IFS= read -r -d '' source; do
      relative="${source#"$package_root/$package/"}"
      target="$HOME/$relative"
      parent="$(dirname "$target")"
      while [[ "$parent" != "$HOME" && "$parent" == "$HOME/"* ]]; do
        if [[ -e "$parent" && ! -d "$parent" ]] || [[ -L "$parent" ]]; then
          printf 'Stow conflict [%s]: parent path is not a real directory: %s\n' "$package" "$parent" >&2
          conflict_count=$((conflict_count + 1)); break
        fi
        parent="$(dirname "$parent")"
      done
      is_replaced=false
      for candidate in ${replaces[@]+"${replaces[@]}"}; do
        [[ "$candidate" != "$target" ]] || is_replaced=true
      done
      if [[ "$is_replaced" == true ]]; then
        continue
      elif [[ -L "$target" ]]; then
        # Both sides are canonicalized, as common/lib/verify.sh's check_symlink
        # does: a link this checkout already owns must compare equal however the
        # checkout was reached.
        resolved="$(resolve_existing_path "$target" 2>/dev/null || true)"
        source_resolved="$(resolve_existing_path "$source" 2>/dev/null || true)"
        if [[ -z "$resolved" ]]; then conflict_type='dangling link'
        elif [[ -n "$source_resolved" && "$resolved" == "$source_resolved" ]]; then continue
        elif [[ "$resolved" == "$canonical_root" || "$resolved" == "$canonical_root/"* ]]; then conflict_type='link to another package in this checkout'
        else conflict_type='link owned by another checkout or source'
        fi
        printf 'Stow conflict [%s]: %s: %s\n' "$package" "$conflict_type" "$target" >&2
        conflict_count=$((conflict_count + 1))
      elif [[ -e "$target" ]]; then
        printf 'Stow conflict [%s]: existing file or directory: %s\n' "$package" "$target" >&2
        conflict_count=$((conflict_count + 1))
      fi
    done < <(find "$package_root/$package" \( -type f -o -type l \) -print0)
  done
  if ((conflict_count > 0)); then
    printf '%d Stow conflict(s) found. Move or back up these paths; --adopt is never automatic.\n' "$conflict_count" >&2
    return 1
  fi
}
