#!/usr/bin/env bash

# Fedora-on-WSL helpers. Source common/lib/common.sh before this file.

is_wsl() {
  local kernel_release_file="${KERNEL_RELEASE_FILE:-/proc/sys/kernel/osrelease}"

  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] ||
    grep -qi microsoft "$kernel_release_file" 2>/dev/null
}

require_fedora_wsl() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local key
  local os_id=""
  local value

  is_wsl || die "This installer must run inside Windows Subsystem for Linux."
  command_exists dnf || die "This installer requires Fedora and DNF."
  command_exists rpm || die "This installer requires Fedora and RPM."
  [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file"

  # Keep the initial platform check free of packages installed by the next
  # phase. Values in os-release use shell-compatible quoting, but only ID is
  # needed here, so parse it without executing the file.
  while IFS='=' read -r key value; do
    if [[ "$key" == "ID" ]]; then
      os_id="${value#\"}"
      os_id="${os_id%\"}"
      break
    fi
  done <"$os_release_file"

  [[ "$os_id" == "fedora" ]] ||
    die "This WSL variant supports the official Fedora distribution only."
}

systemd_is_running() {
  [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" == "systemd" ]]
}

# wsl_session_start_epoch: when this distribution's WSL instance started, in
# whole seconds since the epoch. Prints nothing and fails when /proc cannot
# answer.
#
# WSL reads /etc/wsl.conf once, as the instance starts, and never again until
# "wsl --shutdown" or "wsl --terminate" stops it. So a wsl.conf that changed
# after this moment has not been applied yet, however correct it is, and that
# is the state every first install ends in: configure-interop.sh writes the
# policy and the installer verifies straight after, in the same instance.
#
# PID 1 is this distribution's own init, systemd or WSL's, and it started with
# the instance. Its start time is field 22 of /proc/1/stat, in clock ticks
# since the kernel booted; /proc/stat's btime is that boot in epoch seconds.
# Field 2 is the command name in parentheses and may itself contain spaces or
# a ")", so the fields are counted from the last ")", where field 3 starts.
wsl_session_start_epoch() {
  local proc_root="${WSL_PROC_ROOT:-/proc}"
  local init_stat=""
  local -a init_fields=()
  local key value
  local boot_epoch=""
  local clock_ticks=""

  init_stat="$(cat "$proc_root/1/stat" 2>/dev/null)" || return 1
  [[ "$init_stat" == *")"* ]] || return 1
  read -r -a init_fields <<<"${init_stat##*)}"
  [[ "${init_fields[19]:-}" =~ ^[0-9]+$ ]] || return 1

  [[ -r "$proc_root/stat" ]] || return 1
  while read -r key value _; do
    if [[ "$key" == "btime" ]]; then
      boot_epoch="$value"
      break
    fi
  done <"$proc_root/stat"
  [[ "$boot_epoch" =~ ^[0-9]+$ ]] || return 1

  clock_ticks="$(getconf CLK_TCK 2>/dev/null)" || return 1
  [[ "$clock_ticks" =~ ^[1-9][0-9]*$ ]] || return 1

  printf '%s\n' "$((boot_epoch + init_fields[19] / clock_ticks))"
}

is_windows_path() {
  case "$1" in
  /mnt/[a-zA-Z]/* | *.exe | *.EXE) return 0 ;;
  *) return 1 ;;
  esac
}

# _render_ini_pairs <key=value>...: prints each pair as a "key=value" line.
_render_ini_pairs() {
  local pair
  for pair in "$@"; do
    printf '%s=%s\n' "${pair%%=*}" "${pair#*=}"
  done
}

# render_ini_section_keys <content> <section> <key=value>...: prints
# <content> with [<section>] updated so it contains each key=value pair,
# replacing an existing key's value in place or appending missing keys at
# the end of the section. If the section does not exist, it is appended at
# the end of the file (with a blank separator line first, if the file
# already has content). Every other section, key, comment, and blank line
# is preserved byte-for-byte and in its original position. Pure function:
# it never touches disk itself, which is what makes it independently
# testable and safe to preview under --dry-run.
#
# Key matching is exact-case (wsl.conf's own documented keys, such as
# appendWindowsPath, are not all-lowercase, so case-insensitive matching
# would be more surprising than useful here).
render_ini_section_keys() {
  local content="$1"
  local section="$2"
  shift 2
  local -a want=("$@")

  local -a lines=()
  if [[ -n "$content" ]]; then
    mapfile -t lines <<<"$content"
  fi
  # Normalize away trailing blank lines regardless of how many trailing
  # newlines the caller's string happened to have -- matching what
  # "$(cat file)" already does for real callers, so this function behaves
  # identically for hand-written test strings and real file contents.
  while [[ "${#lines[@]}" -gt 0 && -z "${lines[-1]}" ]]; do
    unset 'lines[-1]'
  done

  local -a out=()
  local -a pending=("${want[@]}")
  local in_section="false"
  local section_seen="false"
  local line header_name key matched pair
  local -a appended still_pending

  for line in "${lines[@]}"; do
    if [[ "$line" =~ ^\[([^]]*)\][[:space:]]*$ ]]; then
      if [[ "$in_section" == "true" && "${#pending[@]}" -gt 0 ]]; then
        mapfile -t appended < <(_render_ini_pairs "${pending[@]}")
        out+=("${appended[@]}")
        pending=()
      fi
      header_name="${BASH_REMATCH[1]}"
      if [[ "$header_name" == "$section" ]]; then
        in_section="true"
        section_seen="true"
      else
        in_section="false"
      fi
      out+=("$line")
      continue
    fi

    if [[ "$in_section" == "true" &&
      "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*= ]]; then
      key="${BASH_REMATCH[1]}"
      matched="false"
      still_pending=()
      for pair in "${pending[@]}"; do
        if [[ "${pair%%=*}" == "$key" ]]; then
          out+=("$key=${pair#*=}")
          matched="true"
        else
          still_pending+=("$pair")
        fi
      done
      pending=("${still_pending[@]}")
      [[ "$matched" == "true" ]] || out+=("$line")
      continue
    fi

    out+=("$line")
  done

  if [[ "$in_section" == "true" && "${#pending[@]}" -gt 0 ]]; then
    mapfile -t appended < <(_render_ini_pairs "${pending[@]}")
    out+=("${appended[@]}")
    pending=()
  fi

  if [[ "$section_seen" == "false" ]]; then
    [[ "${#out[@]}" -eq 0 ]] || out+=("")
    out+=("[$section]")
    mapfile -t appended < <(_render_ini_pairs "${want[@]}")
    out+=("${appended[@]}")
  fi

  printf '%s\n' "${out[@]}"
}

# ini_section_key_value <content> <section> <key>: prints the value <key>
# carries inside [<section>], or nothing when either is absent. The last
# assignment wins, as it does for the parser WSL itself uses. Whitespace
# around the value is stripped, and the key is matched with the same
# exact-case, space-tolerant shape render_ini_section_keys replaces on, so a
# file this repository did not write -- where a key may be spelled
# "key = value" -- reads as the value it actually has rather than as a
# difference in formatting. The two must keep agreeing about what a key line
# is; tests/test-wsl-interop.sh holds them to the same fixtures.
ini_section_key_value() {
  local content="$1"
  local section="$2"
  local key="$3"

  local -a lines=()
  if [[ -n "$content" ]]; then
    mapfile -t lines <<<"$content"
  fi

  local in_section="false"
  local line value=""

  for line in "${lines[@]}"; do
    if [[ "$line" =~ ^\[([^]]*)\][[:space:]]*$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
        in_section="true"
      else
        in_section="false"
      fi
      continue
    fi

    if [[ "$in_section" == "true" &&
      "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$key" ]]; then
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
      fi
    fi
  done

  printf '%s\n' "$value"
}

# windows_interop_probe_path: the full path to the Windows executable used
# to behaviorally verify explicit interop below.
windows_interop_probe_path() {
  local windows_root="${WINDOWS_SYSTEM_ROOT:-/mnt/c/Windows}"
  printf '%s\n' "$windows_root/System32/cmd.exe"
}

# windows_interop_works: true if explicitly invoking a full-path Windows
# executable actually runs. This is deliberately independent of whether
# Windows directories are present in PATH -- appendWindowsPath=false (no
# leakage) and interop enabled=true (explicit .exe execution) are separate
# /etc/wsl.conf keys that can fail independently, and this checks only the
# second one. A broken WSLInterop binfmt registration surfaces here as the
# probe command simply failing to execute (a real "exec format error" case,
# not just a nonzero exit from a well-formed program), which is exactly the
# failure this verifies against.
windows_interop_works() {
  local probe output
  probe="$(windows_interop_probe_path)"

  output="$("$probe" /c echo interop-ok 2>/dev/null)" || return 1
  output="${output%$'\r'}"
  [[ "$output" == "interop-ok" ]]
}

# windows_interop_binfmt_hint: informational only -- prints a comma-joined
# list of WSLInterop*-named entries found under binfmt_misc, or "not found".
# WSL/runtime versions have used different handler names here over time, so
# this is a diagnostic hint alongside windows_interop_works, never a
# replacement for actually running something.
windows_interop_binfmt_hint() {
  local binfmt_root="${BINFMT_MISC_ROOT:-/proc/sys/fs/binfmt_misc}"
  local -a entries=()

  if [[ -d "$binfmt_root" ]]; then
    shopt -s nullglob
    entries=("$binfmt_root"/WSLInterop*)
    shopt -u nullglob
  fi

  if ((${#entries[@]} == 0)); then
    printf 'not found\n'
  else
    local IFS=,
    printf '%s\n' "${entries[*]##*/}"
  fi
}
