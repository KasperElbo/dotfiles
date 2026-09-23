#!/usr/bin/env bash

# Shared read-only verification primitives.
#
# This library deliberately does not select shell options. Verifier entrypoints
# own their execution policy; sourcing a common library must never change the
# caller's errexit, nounset, or pipefail state. It needs version_at_least from
# lib/common.sh and the package identity helpers from lib/mason.sh, and sources
# either itself when the caller has not. Optional capability dispatch reads the
# installation lifecycle record and the capability registry, so it sources those
# two as well; both hold function definitions only, and re-sourcing a library a
# caller already loaded changes nothing.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
if [[ -z "${DOTFILES_MASON_LOADED:-}" ]]; then
  # shellcheck source=mason.sh
  source "$(dirname "${BASH_SOURCE[0]}")/mason.sh"
fi
if [[ -z "${DOTFILES_MARKDOWN_PREVIEW_LOADED:-}" ]]; then
  # shellcheck source=markdown-preview.sh
  source "$(dirname "${BASH_SOURCE[0]}")/markdown-preview.sh"
fi
# shellcheck source=install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-lifecycle.sh"
# shellcheck source=capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/capabilities.sh"

VERIFY_PASSES=${VERIFY_PASSES:-0}
VERIFY_FAILURES=${VERIFY_FAILURES:-0}
VERIFY_WARNINGS=${VERIFY_WARNINGS:-0}
VERIFY_NOT_OBSERVED=${VERIFY_NOT_OBSERVED:-0}

verify_reset() {
  VERIFY_PASSES=0
  VERIFY_FAILURES=0
  VERIFY_WARNINGS=0
  VERIFY_NOT_OBSERVED=0
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# Record which call site in a verifier produced which verdict, when the caller
# asks for a trace by setting DOTFILES_VERIFY_TRACE to a file to append to.
#
# Whether a check can fail is a statement about what ran, so it cannot be read
# out of the file: a predicate that is always true and one that is merely true
# on this machine look identical on the page. The call site is the first frame
# outside this library, which for a check_* helper is the line in the verifier
# that called it, and for a bare pass or fail is that line itself.
#
# A trace that cannot be written is dropped rather than failing the run: a
# verifier's job on a real machine does not depend on it.
_verify_trace() {
  [ -n "${DOTFILES_VERIFY_TRACE:-}" ] || return 0
  local index=1 frame
  while ((index < ${#BASH_SOURCE[@]})); do
    frame="${BASH_SOURCE[index]}"
    case "$frame" in
      */common/lib/verify.sh) index=$((index + 1)) ;;
      *)
        printf '%s\t%s\t%s\n' "$frame" "${BASH_LINENO[index - 1]}" "$1" \
          >>"$DOTFILES_VERIFY_TRACE" 2>/dev/null || true
        return 0
        ;;
    esac
  done
}

pass() {
  _verify_trace pass
  printf '\033[1;32m✓\033[0m %s\n' "$*"
  VERIFY_PASSES=$((VERIFY_PASSES + 1))
  return 0
}

fail() {
  _verify_trace fail
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  return 1
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  return 0
}

# Record a host precondition that this verifier cannot observe or change in the
# current context. This is deliberately distinct from warning and fail.
not_observed() {
  _verify_trace not_observed
  printf '\033[1;36m?\033[0m NOT OBSERVED: %s\n' "$*" >&2
  VERIFY_NOT_OBSERVED=$((VERIFY_NOT_OBSERVED + 1))
  return 0
}

finish_verification() {
  local label="${1:-Verification}"

  printf '\n'
  if ((VERIFY_FAILURES > 0)); then
    printf '\033[1;31m%s failed:\033[0m %d failure(s), %d warning(s), %d unobserved check(s)\n' \
      "$label" "$VERIFY_FAILURES" "$VERIFY_WARNINGS" "$VERIFY_NOT_OBSERVED" >&2
    return 1
  fi

  if ((VERIFY_WARNINGS > 0 && VERIFY_NOT_OBSERVED > 0)); then
    printf '\033[1;36m%s completed with warnings and unobserved checks:\033[0m %d warning(s), %d unobserved check(s)\n' \
      "$label" "$VERIFY_WARNINGS" "$VERIFY_NOT_OBSERVED"
  elif ((VERIFY_NOT_OBSERVED > 0)); then
    printf '\033[1;36m%s completed with unobserved checks:\033[0m %d unobserved check(s)\n' \
      "$label" "$VERIFY_NOT_OBSERVED"
  elif ((VERIFY_WARNINGS > 0)); then
    printf '\033[1;33m%s passed with warnings:\033[0m %d warning(s)\n' \
      "$label" "$VERIFY_WARNINGS"
  else
    printf '\033[1;32m%s passed.\033[0m\n' "$label"
  fi
  return 0
}

# --- Optional capability dispatch -------------------------------------------
#
# Every platform verifier has a run of optional sections, one per capability a
# machine may or may not have asked for. Each was gated on a single record:
# Fedora and Fedora WSL on the capability's component state file, macOS on the
# installer flag. Either alone answers half the question, and the half it
# leaves out is the interesting one -- delete the state file, or interrupt the
# install before it is written, and the capability left the report entirely,
# with nothing said about it either way. A machine that selected --hardening
# and lost hardening.conf verified exactly like one that never selected
# hardening at all (issue #344).
#
# Two records answer it between them. The installation lifecycle record says
# what this machine asked for; the component state file says what the install
# left behind. Dispatch reads both, so a selected capability is always
# described -- verified, or named as a failure -- and state left behind by an
# unselected one is still discovered.
#
# What that state file is called, and what it is allowed to declare itself to
# be, are read from config/capabilities.tsv rather than repeated here: the
# paired "state" and "state_profile" columns are the one record of both, and a
# verifier that restated either is how the two would drift apart.

# verify_optional_capability_state <platform> <capability>
#
# That capability's machine-local state file, composed from the registry the
# way ./install.sh doctor composes it. Fails, printing nothing, for a row that
# records no state of its own.
verify_optional_capability_state() {
  local platform="$1" capability="$2" state_id

  state_id="$(capability_field "$platform" "$capability" state 2>/dev/null)" || return 1
  [[ -n "$state_id" && "$state_id" != - && "$state_id" != install ]] || return 1
  printf '%s/dotfiles/%s.conf\n' "$XDG_CONFIG_HOME" "$state_id"
}

# verify_optional_capability_disposition <platform> <capability>
#
# Prints exactly one word, and returns 0 for the two dispositions that verify:
#
#   verify        selected, with state this checkout can read
#   leftover      not selected, but state remains: verify it, and say so
#   missing       selected, with no state file to verify against     (status 1)
#   corrupt       a state file this checkout cannot read             (status 1)
#   absent        not selected, with nothing left behind             (status 1)
#   unregistered  the registry names no state for this row           (status 1)
#
# A machine with no readable installation record and no state is reported
# "absent", the same answer the LaTeX and OCaml sections already reach: doctor
# reports the missing lifecycle record, and a verifier must not invent a
# selection to put in its place. With a state file it is "verify", which is
# what such a machine has always done.
verify_optional_capability_disposition() {
  local platform="$1" capability="$2"
  local state_path profiles selection=0 readable=1 candidate
  local -a accepted=()

  state_path="$(verify_optional_capability_state "$platform" "$capability")" || {
    printf 'unregistered\n'
    return 1
  }
  # One state file normally declares one profile. hardware.conf is the
  # exception the registry spells out: its profile is the ASUS model, chosen
  # from the machine's DMI identity at install time, so the row names both
  # supported models and verify-asus-hardware.sh compares the recorded one
  # against the hardware. Listing them is the point either way -- a state file
  # does not get to assert its own type.
  profiles="$(capability_field "$platform" "$capability" state_profile 2>/dev/null)" || profiles=""
  if [[ -z "$profiles" || "$profiles" == - ]]; then
    printf 'unregistered\n'
    return 1
  fi

  install_lifecycle_capability_selected "$capability" || selection=$?

  if [[ -e "$state_path" ]]; then
    IFS=, read -r -a accepted <<<"$profiles"
    for candidate in ${accepted[@]+"${accepted[@]}"}; do
      if profile_state_validate_file "$state_path" "$candidate" >/dev/null 2>&1; then
        readable=0
        break
      fi
    done
    if ((readable != 0)); then
      printf 'corrupt\n'
      return 1
    fi
    if ((selection == 1)); then
      printf 'leftover\n'
    else
      printf 'verify\n'
    fi
    return 0
  fi

  if ((selection == 0)); then
    printf 'missing\n'
    return 1
  fi
  printf 'absent\n'
  return 1
}

# verify_optional_capability_report <label> <state-path> <disposition>
#
# Say what a disposition that runs no checks means, in the words of the
# capability rather than of the state file. Callers whose checks are inline use
# this with the disposition helper above; callers whose checks are one
# component verifier use verify_optional_capability, which calls it.
verify_optional_capability_report() {
  local label="$1" state_path="$2" disposition="$3"

  case "$disposition" in
  leftover)
    warning "$label is not selected by this machine's recorded installation," \
      "but its profile state remains ($state_path), so what that state" \
      "describes is verified anyway; rerun ./install.sh with the capability" \
      "to adopt it, or remove the state by hand"
    ;;
  missing)
    fail "$label is selected by this machine's recorded installation, but its" \
      "profile state is missing ($state_path), so nothing about it can be" \
      "verified; reinstall the capability, or rerun ./install.sh without it"
    ;;
  corrupt)
    fail "$label is recorded on this machine, but this checkout cannot read" \
      "its profile state ($state_path); inspect it with ./install.sh doctor," \
      "then reinstall the capability"
    ;;
  unregistered)
    fail "$label cannot be verified: config/capabilities.tsv names no state" \
      "file and schema for it on this platform, so there is nothing to decide" \
      "from. This is a defect in the registry, not on this machine."
    ;;
  absent)
    pass "$label is not selected; its state and checks are not applicable"
    ;;
  esac
}

# verify_optional_capability <label> <platform> <capability> <command...>
#
# The whole optional section for the common case: a capability whose checks are
# one component verifier. Opens the section, dispatches, and reports.
verify_optional_capability() {
  local label="$1" platform="$2" capability="$3"
  shift 3
  local disposition state_path

  section "$label"
  state_path="$(verify_optional_capability_state "$platform" "$capability" || true)"
  disposition="$(verify_optional_capability_disposition "$platform" "$capability")" || true
  # fail returns 1, and this library must not decide its caller's errexit.
  verify_optional_capability_report "$label" "$state_path" "$disposition" || true

  case "$disposition" in
  verify | leftover)
    if "$@"; then
      pass "$label verification completed"
    else
      fail "$label verification failed"
    fi
    ;;
  esac
}

# verify_default_probe <name>
#
# Print the functional probe `check_command <name> --probe` runs, as
# "<arguments>|<required output>". Most commands answer --version and exit 0.
# The exceptions are documented here rather than at each call site:
#
#   ssh, tmux  report their version with -V; --version is an unknown option.
#   scp, sftp  have no offline invocation that exits 0. Run with no operands
#              they print their own usage text and exit 1, so that text is the
#              proof the binary started; a binary the loader cannot start
#              prints nothing of the kind.
#
# wl-copy and wl-paste need no override: they answer --version before they
# connect to a Wayland display, so the probe works in a headless session.
verify_default_probe() {
  case "$1" in
  ssh | tmux) printf '%s|\n' -V ;;
  scp | sftp) printf '|usage: %s\n' "$1" ;;
  *) printf '%s|\n' --version ;;
  esac
}

# check_command <name> [--probe [arguments]]
#
# Without --probe this proves only that <name> resolves on PATH, which is not
# the same as a command that works: a corrupt install, a binary linked against
# a missing shared library, a wrong-architecture binary and a stale Homebrew or
# Mason symlink all resolve. --probe also runs the resolved command, with
# verify_default_probe's arguments or with the space-separated arguments given,
# and fails unless it exits 0 (or prints the output a default probe requires).
# Standard input is closed so a probe can never wait for it.
check_command() {
  local command_name="$1"
  local command_path probe_spec probe_output
  local probe="false" probe_arguments="" probe_expected="" probe_status=0
  local -a probe_argv=()
  shift

  case "${1:-}" in
  "") ;;
  --probe)
    probe="true"
    if (($# >= 2)); then
      probe_arguments="$2"
    else
      probe_spec="$(verify_default_probe "$command_name")"
      probe_arguments="${probe_spec%%|*}"
      probe_expected="${probe_spec#*|}"
    fi
    ;;
  *)
    fail "check_command $command_name: unsupported argument: $1"
    return 1
    ;;
  esac

  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    fail "$command_name not found"
    return 1
  fi
  if [[ "$probe" == false ]]; then
    pass "$command_name: $command_path"
    return 0
  fi

  read -r -a probe_argv <<<"$probe_arguments"
  probe_output="$("$command_path" ${probe_argv[@]+"${probe_argv[@]}"} </dev/null 2>&1)" ||
    probe_status=$?
  if [[ -n "$probe_expected" ]]; then
    if [[ "$probe_output" == *"$probe_expected"* ]]; then
      pass "$command_name runs: $command_path"
      return 0
    fi
  elif ((probe_status == 0)); then
    pass "$command_name runs: $command_path"
    return 0
  fi

  fail "$command_name resolves to $command_path but does not run:" \
    "'$command_name${probe_arguments:+ $probe_arguments}' exited $probe_status" \
    "(${probe_output%%$'\n'*})"
}

check_version_at_least() {
  local label="$1"
  local actual="$2"
  local minimum="$3"

  if [[ -z "$minimum" ]]; then
    fail "$label has no declared version floor to check against"
  elif version_at_least "$actual" "$minimum"; then
    pass "$label $actual satisfies the >= $minimum baseline"
  else
    fail "$label ${actual:-unknown} does not satisfy the >= $minimum baseline"
  fi
}

# check_file_contains <label> <path> <expected>
#
# The expected text occurs on a line of the file that is in effect. Blank
# lines and whole-line comments are dropped before the match, because the
# callers are settings files and the thing being reported is that a setting
# applies: a directive someone commented out satisfied this check, and one
# file could prove two mutually exclusive theme flavours present at once
# (issue #390, VL-01).
#
# It still proves a substring rather than a whole line. Three of the four
# call sites pass a fragment of a longer line, so anchoring the claim to the
# line belongs with them rather than here.
check_file_contains() {
  local label="$1"
  local path="$2"
  local expected="$3"
  local active=""

  # Read once and match a here-string rather than piping the file into a
  # quiet grep, which takes SIGPIPE exactly when the match is found
  # (docs/testing.md, "Assertions that cannot fail").
  if [[ -r "$path" ]]; then
    active="$(grep -Ev '^[[:space:]]*(#|$)' -- "$path" || true)"
  fi

  if [[ -n "$active" ]] && grep -Fq -- "$expected" <<<"$active"; then
    pass "$label"
  else
    fail "$label: expected '$expected' in $path, on a line that is in effect"
  fi
}

verify_file_mode() {
  local path="$1"
  local mode

  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
  fi
  [[ -n "$mode" ]] || return 1
  printf '%s\n' "$mode"
}

# Resolve an existing path without GNU-only readlink flags. Installers and
# verifiers must agree on what a path resolves to, so the implementation lives
# in common/lib/common.sh (sourced before this library by every verifier) and
# this is the verifier-facing name for it.
verify_canonical_existing_path() {
  resolve_existing_path "$1"
}

verify_path_is_within_root() {
  local path="$1"
  local root="${2%/}"

  [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

# check_symlink <link> <expected-root> [expected-source]
#
# An owned Stow link has five independent properties: the link object exists,
# it is a symlink, its referent exists, canonical resolution succeeds, and the
# resolved referent is inside the exact expected package root. The root test
# is component-aware so /repo/dotfiles-other never satisfies /repo/dotfiles.
#
# Those five prove the link points somewhere below the right package. They do
# not prove it points at the right file: a link redirected at another file in
# the same package passed, so a manual mislink, a faulty migration or a
# Stow-layout regression could send a configuration path at the wrong
# repository file and still be reported green (issue #369).
#
# <expected-source> is that sixth property. Given it, the resolved referent
# must be that exact file and no other. Both sides are canonicalized first, so
# a relative and an absolute spelling of the same source agree, and so does a
# checkout reached through a symlink. Call sites that do not pass it keep the
# weaker containment guarantee and say so by their argument count.
check_symlink() {
  local link="$1"
  local expected_root="${2%/}"
  local expected_source="${3:-}"
  local resolved=""
  local canonical_root=""
  local canonical_source=""

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    fail "$link is missing; expected Stow ownership under $expected_root"
    return 1
  fi
  if [[ ! -L "$link" ]]; then
    fail "$link is not a symlink; expected Stow ownership under $expected_root"
    return 1
  fi
  if [[ ! -e "$link" ]]; then
    fail "$link is a dangling symlink; expected a live referent under $expected_root"
    return 1
  fi

  resolved="$(verify_canonical_existing_path "$link" 2>/dev/null || true)"
  canonical_root="$(verify_canonical_existing_path "$expected_root" 2>/dev/null || true)"
  if [[ -z "$resolved" || -z "$canonical_root" ]]; then
    fail "$link could not be canonically resolved; resolved=${resolved:-<none>} expected=$expected_root"
    return 1
  fi

  if ! verify_path_is_within_root "$resolved" "$canonical_root"; then
    fail "$link is not owned by the expected package; resolved=$resolved expected=$canonical_root"
    return 1
  fi

  if [[ -n "$expected_source" ]]; then
    canonical_source="$(verify_canonical_existing_path "$expected_source" 2>/dev/null || true)"
    if [[ -z "$canonical_source" ]]; then
      fail "$link cannot be checked against its Stow source: $expected_source" \
        "does not exist in this checkout"
      return 1
    fi
    if [[ "$resolved" != "$canonical_source" ]]; then
      fail "$link is owned by $canonical_root but is not the file Stow should" \
        "have linked; resolved=$resolved expected=$canonical_source"
      return 1
    fi
  fi

  pass "$link -> $resolved"
  return 0
}

check_system_service_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    pass "$unit is active"
  else
    fail "$unit is not active"
  fi
}

# verify_unit_state <system|user> <is-enabled|is-active> <unit>
verify_unit_state() {
  if [[ "$1" == user ]]; then
    systemctl --user "$2" --quiet "$3" 2>/dev/null
  else
    systemctl "$2" --quiet "$3" 2>/dev/null
  fi
}

verify_service_enabled_and_active() {
  local scope="$1" unit="$2" owner="" enabled="false" active="false"

  [[ "$scope" != user ]] || owner=" for the user"
  verify_unit_state "$scope" is-enabled "$unit" && enabled="true"
  verify_unit_state "$scope" is-active "$unit" && active="true"

  case "$enabled:$active" in
  true:true)
    pass "$unit is enabled and active$owner"
    ;;
  true:false)
    fail "$unit is enabled$owner but not active; it is not running now"
    ;;
  false:true)
    fail "$unit is active$owner but not enabled; it will not start after a reboot"
    ;;
  *)
    fail "$unit is neither enabled nor active$owner"
    ;;
  esac
}

# check_system_service_enabled_and_active <unit>
# check_user_service_enabled_and_active <unit>
#
# A service that is running but not enabled passes an is-active check today
# and is gone after the next reboot, so a service this repository relies on to
# stay up must be both. The failure names the missing half, because "enabled
# but stopped" and "running but will not survive a reboot" are fixed
# differently. is-active alone remains the right check for a unit that is
# activated by a device or started on demand, whose enablement is not what
# brings it up.
check_system_service_enabled_and_active() {
  verify_service_enabled_and_active system "$1"
}

check_user_service_enabled_and_active() {
  verify_service_enabled_and_active user "$1"
}

# verify_mason_ready [version_pin_file]
#
# Make the receipt reader and the version pins ready for the checks below, once
# per verifier rather than once per package. Neither failure is skipped: a check
# that credited every package because jq was missing, or that stopped comparing
# pins because the pin file had a line it could not parse, would report a clean
# machine. Returns non-zero having said which, so the caller stops.
verify_mason_ready() {
  local pin_file="${1:-$DOTFILES_ROOT/common/mason-package-versions.txt}"

  if ! mason_require_jq; then
    fail "Mason packages cannot be verified: $MASON_ERROR"
    return 1
  fi
  if ! mason_load_version_pins "$pin_file"; then
    fail "$MASON_ERROR"
    return 1
  fi
}

# check_mason_package <mason_root> <package>
#
# Report one package against lib/mason.sh's rule, at the version the pins
# verify_mason_ready loaded demand. This is separate from the inventory check
# below because a platform can own its inventory policy and still owe the same
# answer about a package: the Parrot guest treats an unlisted package as a
# failure rather than a warning, and says exactly this about a listed one.
check_mason_package() {
  local root="$1" package="$2"
  local pin

  pin="$(mason_version_pin "$package")"
  if mason_package_status "$root" "$package" "$pin"; then
    pass "Mason: $package ($MASON_PACKAGE_DETAIL)"
    return 0
  fi
  case "$MASON_PACKAGE_STATE" in
  absent)
    fail "Mason package not installed: $package"
    ;;
  version-mismatch)
    fail "Mason package $package does not match its pin: $MASON_PACKAGE_DETAIL"
    ;;
  *)
    fail "Mason package $package is not completely installed: $MASON_PACKAGE_DETAIL"
    ;;
  esac
  return 1
}

# check_mason_inventory <inventory> [version_pin_file]
#
# Every package the tracked Mason inventory lists must be installed under
# Mason's package root, at its pinned version where one is recorded. "Installed"
# is lib/mason.sh's business and not a directory that exists: Mason writes a
# package's receipt only once its files are extracted and its executables
# linked, so an interrupted install leaves behind a directory this check must
# report rather than credit. A package Mason holds that the inventory does not
# list is a warning rather than a failure: it may be a deliberate local
# addition, but nothing in this repository owns it.
check_mason_inventory() {
  local inventory="$1"
  local pin_file="${2:-$DOTFILES_ROOT/common/mason-package-versions.txt}"
  local root
  root="$(mason_root)"
  local package package_dir listed filtered status=0
  local -a packages=()

  if [[ ! -e "$inventory" ]]; then
    fail "Mason package inventory missing: $inventory"
    return 1
  fi
  # Something that is not a readable regular file is a read failure, not an
  # empty inventory, and the distinction is made here rather than left to sed:
  # GNU sed exits non-zero on a directory, but BSD sed on macOS exits 0 having
  # printed nothing, which would arrive below as an empty list and be reported
  # as an empty inventory on exactly the platform this function was fixed for.
  if [[ ! -f "$inventory" || ! -r "$inventory" ]]; then
    fail "Mason package inventory could not be read: $inventory"
    return 1
  fi
  # macOS's system Bash is 3.2 and has no mapfile, so this reads the inventory
  # with a loop instead. mason_read_inventory does the comment and blank-line
  # filtering and preserves the package order. Its output is captured rather
  # than read through a process substitution so its status survives: the guards
  # above cover every read failure that can be produced on demand, and this
  # covers the residual one, an I/O error part-way through a file that was a
  # readable regular file when it was tested. The empty-string guard below is
  # needed because a here-string of "" still yields one empty line.
  filtered="$(mason_read_inventory "$inventory")" || {
    fail "Mason package inventory could not be read: $inventory"
    return 1
  }
  if [[ -n "$filtered" ]]; then
    while IFS= read -r package; do
      packages+=("$package")
    done <<<"$filtered"
  fi
  if ((${#packages[@]} == 0)); then
    fail "Mason package inventory is empty: $inventory"
    return 1
  fi

  verify_mason_ready "$pin_file" || return 1

  for package in "${packages[@]}"; do
    check_mason_package "$root" "$package" || status=1
  done

  for package_dir in "$root"/packages/*; do
    [[ -d "$package_dir" ]] || continue
    package="${package_dir##*/}"
    for listed in "${packages[@]}"; do
      [[ "$package" != "$listed" ]] || continue 2
    done
    warning "Unexpected Mason package (review ownership): $package"
  done
  return "$status"
}

# How long any verifier will wait for the deployed configuration to start.
# Every platform uses the same bound, because a start that needs longer than
# this is a machine to report and not one to keep waiting on: the Fedora
# verifier used to apply no bound at all, and a failed lazy.nvim clone left it
# blocked on getchar() with nothing to end the run.
NEOVIM_VERIFY_START_TIMEOUT="${NEOVIM_VERIFY_START_TIMEOUT:-2m}"

# neovim_verify_floor_assertion <floor>
#
# The Ex command that makes Neovim assert its own version. A Lua error raised
# from an Ex command never reaches the exit status, so the assertion has to
# call cquit itself rather than rely on the error propagating
# (tests/test-neovim-tool-ownership.sh holds it to that). Written once here
# because all four platforms ask the same question.
neovim_verify_floor_assertion() {
  printf '+lua if vim.fn.has("nvim-%s") ~= 1 then vim.cmd("cquit 1") end\n' "$1"
}

# check_neovim_starts <label> <floor> [command ...]
#
# Start the deployed configuration and prove it both loads and meets the floor,
# without changing the machine. DOTFILES_NVIM_VERIFY=1 is what makes that true:
# without it the configuration clones a missing lazy.nvim and installs every
# plugin the profile names and does not find, so the start repaired the tree
# the verifier was inspecting and then credited the result (#371).
#
# The command defaults to nvim on PATH. A platform that has to reach Neovim
# some other way passes its own, as long as it names a program: this bounds the
# start with timeout, which cannot run a shell function.
check_neovim_starts() {
  local label="$1" floor="$2"
  shift 2
  local log status=0
  [[ $# -gt 0 ]] || set -- nvim

  log="$(mktemp)"
  DOTFILES_NVIM_VERIFY=1 timeout --kill-after=10s \
    "$NEOVIM_VERIFY_START_TIMEOUT" \
    "$@" --headless "$(neovim_verify_floor_assertion "$floor")" +qa \
    >"$log" 2>&1 || status=$?

  if ((status == 0)); then
    pass "$label starts and reports >= $floor"
  elif ((status == 124 || status == 137)); then
    fail "$label did not finish starting within $NEOVIM_VERIFY_START_TIMEOUT"
    sed 's/^/  /' "$log" >&2
  else
    fail "$label startup/version check failed (requires >= $floor)"
    sed 's/^/  /' "$log" >&2
  fi
  rm -f -- "$log"
  return "$status"
}

# lazy_plugin_root
#
# Where lazy.nvim checks plugins out. Neovim's stdpath("data") is
# $XDG_DATA_HOME/nvim and nothing in this repository moves it, so this is the
# one place the path is written down.
lazy_plugin_root() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy"
}

# check_lazy_plugin_state <lockfile>
#
# Prove that this machine's Lazy plugin tree is the one the profile's lock file
# names: every plugin checked out, and each at the exact commit. Offline by
# construction -- it reads the lock file and Git's own HEAD and asks the
# network nothing, so a machine that cannot reach GitHub is still judged rather
# than excused.
#
# This has to run *before* Neovim is started, because a start cannot be the
# evidence. The deployed configuration exists to make a workstation usable, so
# left alone it installs whatever the profile names and does not find: a start
# that reaches the end proves only that anything missing has since been
# fetched, which is the defect in #371. Starting under DOTFILES_NVIM_VERIFY=1
# stops the repair; this answers the question the start no longer can.
#
# lazy.nvim is an ordinary entry in the lock file, so a missing bootstrap is
# reported by name here like any other plugin.
check_lazy_plugin_state() {
  local lockfile="$1"
  local root entries plugin expected actual listed plugin_dir status=0
  local -a locked=()

  root="$(lazy_plugin_root)"

  # jq and git are baseline packages on every platform whose verifier reaches
  # this code. Their absence is an error, never a quietly skipped check: a run
  # that credited a machine because its JSON parser was missing would report a
  # clean plugin tree it never looked at.
  if ! command_exists jq; then
    fail "Lazy plugins cannot be verified: jq is required to read $lockfile"
    return 1
  fi
  if ! command_exists git; then
    fail "Lazy plugins cannot be verified: git is required to read plugin checkouts"
    return 1
  fi

  if [[ ! -e "$lockfile" ]]; then
    fail "Lazy lock file missing: $lockfile"
    return 1
  fi
  if [[ ! -f "$lockfile" || ! -r "$lockfile" ]]; then
    fail "Lazy lock file could not be read: $lockfile"
    return 1
  fi

  # A lock file this checkout cannot parse is a failure and never an empty
  # plugin set. jq's exit status is the only thing that separates the two, so
  # its output is captured rather than read through a process substitution,
  # where the status would be lost and a corrupt file would arrive here as
  # "no plugins locked".
  entries="$(jq -r 'to_entries[] | [.key, (.value.commit // "")] | @tsv' \
    "$lockfile" 2>/dev/null)" || {
    fail "Lazy lock file is not valid JSON: $lockfile"
    return 1
  }
  if [[ -z "$entries" ]]; then
    fail "Lazy lock file names no plugins: $lockfile"
    return 1
  fi

  if [[ ! -d "$root" ]]; then
    fail "Lazy plugin root missing: $root"
    return 1
  fi

  # macOS's system Bash is 3.2 and has no mapfile, so this reads the captured
  # output with a loop.
  while IFS=$'\t' read -r plugin expected; do
    [[ -n "$plugin" ]] || continue
    locked+=("$plugin")
    if [[ -z "$expected" ]]; then
      fail "Lazy lock file records no commit for $plugin: $lockfile"
      status=1
      continue
    fi
    if [[ ! -d "$root/$plugin" ]]; then
      fail "Lazy plugin not installed: $plugin (expected $expected)"
      status=1
      continue
    fi
    # A directory is not a checkout: an interrupted clone leaves one behind,
    # and rev-parse is what tells the two apart.
    actual="$(git -C "$root/$plugin" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$actual" ]]; then
      fail "Lazy plugin is not a Git checkout: $plugin ($root/$plugin)"
      status=1
      continue
    fi
    if [[ "$actual" != "$expected" ]]; then
      fail "Lazy plugin commit mismatch: $plugin (expected $expected, found $actual)"
      status=1
    fi
  done <<<"$entries"

  # A plugin the lock file does not name is a warning rather than a failure,
  # the same call check_mason_inventory makes: it may be a deliberate local
  # addition, but nothing in this repository owns it, and on a verified machine
  # it is also how a repairing run leaves its fingerprints.
  for plugin_dir in "$root"/*; do
    [[ -d "$plugin_dir" ]] || continue
    plugin="${plugin_dir##*/}"
    for listed in ${locked[@]+"${locked[@]}"}; do
      [[ "$plugin" != "$listed" ]] || continue 2
    done
    warning "Unexpected Lazy plugin (review ownership): $plugin"
  done

  if ((status == 0)); then
    pass "Lazy plugins match ${#locked[@]} locked commits: $lockfile"
  fi
  return "$status"
}

# check_markdown_preview_server <lockfile>
#
# A markdown-preview.nvim checkout at its locked commit is not a working
# preview: the page is served by a binary the plugin's build downloads, and an
# install whose build never finished left the checkout and no server. The
# preview then opened no browser on every platform while check_lazy_plugin_state
# passed. lib/markdown-preview.sh decides, so this cannot credit what the
# installer would repair. A profile whose lock file does not name the plugin
# has no preview to check.
check_markdown_preview_server() {
  local lockfile="$1"
  local plugin_dir locked

  if ! command_exists jq; then
    fail "Markdown preview server cannot be verified: jq is required to read $lockfile"
    return 1
  fi
  # A lock file jq cannot read is a failure, never a profile without a preview.
  locked="$(jq -r 'has("markdown-preview.nvim")' "$lockfile" 2>/dev/null)" || {
    fail "Markdown preview server cannot be verified: $lockfile is not readable JSON"
    return 1
  }
  [[ "$locked" == true ]] || return 0
  plugin_dir="$(lazy_plugin_root)/markdown-preview.nvim"
  if [[ ! -d "$plugin_dir" ]]; then
    # check_lazy_plugin_state has already failed the missing checkout.
    fail "Markdown preview server not observed: markdown-preview.nvim is not installed"
    return 1
  fi

  if markdown_preview_server_status "$plugin_dir"; then
    pass "Markdown preview server: $MARKDOWN_PREVIEW_DETAIL"
    return 0
  fi
  if [[ "$MARKDOWN_PREVIEW_STATE" == unsupported ]]; then
    warning "Markdown preview unavailable: $MARKDOWN_PREVIEW_DETAIL"
    return 0
  fi
  fail "Markdown preview server $MARKDOWN_PREVIEW_STATE: $MARKDOWN_PREVIEW_DETAIL" \
    "(rerun the installer, or :Lazy build markdown-preview.nvim)"
  return 1
}

# The Catppuccin tmux version common/install-tmux-theme.sh pins. It is read
# from the installer rather than repeated here, so bumping the pin cannot
# leave a verifier expecting the previous tag.
verify_catppuccin_tmux_pin() {
  sed -n 's/^version="\(v[0-9][0-9.]*\)"$/\1/p' \
    "$DOTFILES_ROOT/common/install-tmux-theme.sh" 2>/dev/null
}

# check_catppuccin_tmux
#
# The plugin checkout tmux/.tmux.conf runs must exist. A checkout that has moved
# off the pinned tag still works, so it is a warning naming both versions.
check_catppuccin_tmux() {
  local plugin_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/plugins/catppuccin"
  local pin installed_commit pinned_commit installed_version

  if [[ ! -f "$plugin_dir/catppuccin.tmux" ]]; then
    fail "Catppuccin tmux is missing: $plugin_dir/catppuccin.tmux"
    return 1
  fi
  pass "Catppuccin tmux installed: $plugin_dir"

  pin="$(verify_catppuccin_tmux_pin)"
  if [[ -z "$pin" ]]; then
    fail "Could not read the pinned Catppuccin tmux version from" \
      "$DOTFILES_ROOT/common/install-tmux-theme.sh"
    return 1
  fi
  installed_commit="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"
  pinned_commit="$(git -C "$plugin_dir" rev-list -n 1 "$pin" 2>/dev/null || true)"
  if [[ -n "$installed_commit" && "$installed_commit" == "$pinned_commit" ]]; then
    pass "Catppuccin tmux is at the pinned $pin"
  else
    installed_version="$(git -C "$plugin_dir" describe --tags --always HEAD 2>/dev/null || true)"
    warning "Catppuccin tmux is at ${installed_version:-an unknown version}, not the pinned $pin"
  fi
}

# Shared mise ownership check. Callers that mutate PATH after sourcing should
# set VERIFY_CALLER_PATH to the original PATH first. VERIFY_MISE_COMMAND may be
# supplied by a verifier; otherwise the normal repository resolver is used.
# check_login_environment <name> <expected>: the value a fresh Zsh login gives
# the variable. Read from a login shell rather than from this process, because
# an exported value in the verifier's own environment proves nothing about the
# environment the next `claude` will start in. Deliberately `zsh -lc` rather
# than the `zsh -lic` used elsewhere in this file: the setting has to survive a
# login that is not interactive, which is what rules out an interactive-only
# definition satisfying the check by accident.
#
# What this cannot prove: that the variable reaches a process this shell did
# not start. Anything launched outside a top-level Zsh -- an editor, a
# launcher, a shell that predates the install -- reads none of .zshenv, so for
# Claude Code specifically this is the second line and not the block itself.
# See check_claude_update_settings below.
#
# The probe prints its own marker and an explicit sentinel for an unset
# variable, so the three outcomes stay distinguishable. The marker is matched
# anywhere on the line because a login shell is free to write control sequences
# before it. A shell that answers something else -- a stub, or a login that died
# before the printf -- is a check this context could not make, not evidence that
# the variable is missing.
check_login_environment() {
  local name="$1"
  local expected="$2"
  local answer

  if ! command_exists zsh; then
    not_observed "zsh is unavailable; cannot prove $name is set for a fresh login"
    return
  fi

  answer="$(
    zsh -lc "printf 'login-env:%s\n' \"\${$name-<unset>}\"" 2>/dev/null |
      sed -n 's/.*login-env://p' | tail -n 1
  )"

  case "$answer" in
  "$expected")
    pass "$name=$expected in a fresh Zsh login"
    ;;
  "")
    not_observed "the login shell did not answer the $name probe;" \
      "cannot prove Claude Code's updater is disabled for a fresh login"
    ;;
  "<unset>")
    fail "$name is unset in a fresh Zsh login; Claude Code would update itself" \
      "outside mise. Restow the zsh package so ~/.zshenv exports it"
    ;;
  *)
    fail "$name is '$answer' in a fresh Zsh login, not $expected;" \
      "Claude Code would update itself outside mise"
    ;;
  esac
}

# check_claude_update_settings <settings-file> <key>...: the update block that
# survives a launch this repository did not start.
#
# check_login_environment above can only prove what a Zsh it starts itself
# exports. Claude Code is routinely launched by something that is not a
# descendant of a top-level Zsh -- an editor, a launcher, a shell that was
# already running when the profile was installed -- and such a process gets
# none of .zshenv. Claude Code reads its own settings file whatever started it,
# so that file is where the block has to be, and here is where it is proven.
#
# A key set to anything other than "1" is a failure rather than a warning: the
# tool's gate is what it is, and a value it does not accept leaves the updater
# free to write a second copy into the active Node prefix, which is exactly the
# state check_no_global_npm_duplicate then reports.
check_claude_update_settings() {
  local file="$1"
  shift
  local key value missing="false"

  if ! command_exists jq; then
    not_observed "jq is unavailable; cannot read $file to prove that Claude" \
      "Code's updater is disabled"
    return
  fi

  if [[ ! -e "$file" ]]; then
    fail "$file does not exist, so Claude Code's updater is unrestricted" \
      "however it is launched. Rerun './common/install-ai.sh' to declare $*"
    return 1
  fi

  if ! jq -e . "$file" >/dev/null 2>&1; then
    fail "$file is not valid JSON, so Claude Code reads no settings from it" \
      "and its updater is unrestricted. Repair the file, then rerun" \
      "'./common/install-ai.sh'"
    return 1
  fi

  for key in "$@"; do
    value="$(jq -r --arg key "$key" '.env[$key] // "<unset>"' "$file" 2>/dev/null)"
    if [[ "$value" == "1" ]]; then
      pass "$key=1 in $file"
    else
      fail "$key is $value in $file, not 1; Claude Code would install a" \
        "second copy of itself into the active Node prefix. Rerun" \
        "'./common/install-ai.sh'"
      missing="true"
    fi
  done

  [[ "$missing" == false ]]
}

# check_no_global_npm_duplicate <package>...: an AI package installed into the
# active Node prefix as well as its dedicated mise npm backend. The duplicate
# shadows the backend installation, so mise no longer owns what actually runs.
#
# npm is reached through mise so the prefix inspected is the one the mise-managed
# Node actually uses, rather than whatever npm happens to sit on the caller's
# PATH. The diagnostic carries the recovery command but the installer does not
# run it: a package this repository did not install is unproven external state,
# and deleting it silently is the one thing the ownership model must not do.
check_no_global_npm_duplicate() {
  local global_npm prefix status duplicate="false" package mise_command

  mise_command="${VERIFY_MISE_COMMAND:-}"
  if [[ -z "$mise_command" ]] && declare -F resolve_mise_command >/dev/null 2>&1; then
    mise_command="$(resolve_mise_command 2>/dev/null || true)"
  fi
  if [[ -z "$mise_command" ]]; then
    not_observed "mise is unavailable; cannot inspect the active Node prefix" \
      "for duplicate AI packages"
    return
  fi

  if declare -F run_mise >/dev/null 2>&1; then
    global_npm="$(run_mise "$mise_command" exec -- npm ls --global --depth=0 --parseable 2>/dev/null)"
  else
    global_npm="$("$mise_command" exec -- npm ls --global --depth=0 --parseable 2>/dev/null)"
  fi
  status=$?
  # npm reports a dependency problem in the tree with a non-zero exit while
  # still printing the tree, so keying the not_observed branch on the status
  # alone reported a run that enumerated the prefix and named the duplicate as
  # a run that could not happen (issue #396, GAP-35). What separates "could
  # not run" from "ran and exited non-zero" is whether there is any output:
  # with none there is nothing to read, and only then is this unobserved.
  if ((status != 0)) && [[ -z "$global_npm" ]]; then
    not_observed "npm produced no output under mise; cannot rule out a" \
      "duplicate AI package in the active Node prefix"
    return
  fi

  if declare -F run_mise >/dev/null 2>&1; then
    prefix="$(run_mise "$mise_command" exec -- npm prefix --global 2>/dev/null || true)"
  else
    prefix="$("$mise_command" exec -- npm prefix --global 2>/dev/null || true)"
  fi
  for package in "$@"; do
    if [[ "$global_npm" == *"/node_modules/$package" ]] ||
      [[ "$global_npm" == *"/node_modules/$package"$'\n'* ]]; then
      fail "$package is also installed globally with npm under" \
        "${prefix:-the active Node prefix}; the AI profile is mise-owned." \
        "Remove only the duplicate and reshim:" \
        "npm uninstall -g $package && mise reshim"
      duplicate="true"
    fi
  done

  if [[ "$duplicate" == true ]]; then
    return
  fi

  # Output was read and named no duplicate. If npm still exited non-zero, the
  # tree it printed may be incomplete, so absence of a duplicate in it is not
  # proof of absence.
  if ((status != 0)); then
    not_observed "npm exited $status while listing the active Node prefix and" \
      "named no duplicate AI package; the listing may be incomplete"
    return
  fi

  pass "No AI package is duplicated in the active Node prefix"
}

# The deterministic mise context is this verifier's own precondition: every
# mise question below is asked from it, so a missing or contaminated context
# makes the answers meaningless. It is reported, never repaired. Verification
# is documented as read-only (docs/workflows/verification.md), and rebuilding
# the context here would delete exactly the contamination worth reporting and
# then pass.
check_mise_context() {
  local diagnosis

  if ! declare -F mise_context_diagnosis >/dev/null 2>&1; then
    not_observed "the deterministic mise context cannot be inspected from here;" \
      "common/lib/common.sh is not loaded"
    return 0
  fi

  if diagnosis="$(mise_context_diagnosis)"; then
    pass "The deterministic mise context is present and declares no tools"
    return 0
  fi

  fail "mise resolution is not deterministic: $diagnosis"
}

# verify_login_path <interactive|non-interactive>: the PATH a fresh Zsh login
# configures, read with check_login_environment's marker-and-sed discipline so
# a .zshrc that writes to stdout cannot become the first PATH component.
# Fails, printing nothing, when zsh is unavailable or answers nothing.
verify_login_path() {
  local mode="$1" answer

  command_exists zsh || return 1
  case "$mode" in
  interactive)
    answer="$(zsh -lic 'printf "login-path:%s\n" "$PATH"' 2>/dev/null |
      sed -n 's/.*login-path://p' | tail -n 1)"
    ;;
  non-interactive)
    answer="$(zsh -lc 'printf "login-path:%s\n" "$PATH"' 2>/dev/null |
      sed -n 's/.*login-path://p' | tail -n 1)"
    ;;
  *) return 1 ;;
  esac

  [[ -n "$answer" ]] || return 1
  printf '%s\n' "$answer"
}

check_mise_owned() {
  local name="$1"
  local resolved mise_resolved mise_shim configured_path configured_resolved mise_command
  local mise_data_dir mise_shims_dir login_resolved

  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    fail "$name not found"
    return 1
  fi

  mise_command="${VERIFY_MISE_COMMAND:-}"
  if [[ -z "$mise_command" ]] && declare -F resolve_mise_command >/dev/null 2>&1; then
    mise_command="$(resolve_mise_command 2>/dev/null || true)"
  fi
  if [[ -z "$mise_command" ]]; then
    fail "mise not found; cannot prove ownership of $name ($resolved)"
    return 1
  fi

  # Resolution must use the same deterministic context as installation, or a
  # verifier run from inside a project could resolve that project's tool.
  if declare -F run_mise >/dev/null 2>&1; then
    mise_resolved="$(run_mise "$mise_command" which "$name" 2>/dev/null || true)"
  else
    mise_resolved="$("$mise_command" which "$name" 2>/dev/null || true)"
  fi
  if [[ -z "$mise_resolved" || ! -x "$mise_resolved" ]]; then
    fail "$name is not backed by an executable reported by mise: ${mise_resolved:-<none>}"
    return 1
  fi

  mise_data_dir="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  mise_shims_dir="${MISE_SHIMS_DIR:-$mise_data_dir/shims}"
  mise_shim="$mise_shims_dir/$name"
  # Prefer the path a fresh login would actually configure. The legacy
  # VERIFY_CALLER_PATH remains supported for hermetic tests and callers that
  # intentionally provide an explicit pre-mutation PATH.
  if [[ -n "${VERIFY_CONFIGURED_LOGIN_PATH+x}" ]]; then
    configured_path="$VERIFY_CONFIGURED_LOGIN_PATH"
  elif [[ -n "${VERIFY_CALLER_PATH+x}" ]]; then
    configured_path="$VERIFY_CALLER_PATH"
  elif command_exists zsh; then
    configured_path="$(zsh -lic 'printf "%s\\n" "$PATH"' 2>/dev/null || true)"
  else
    configured_path="${PATH:-}"
  fi
  if [[ -z "$configured_path" ]]; then
    fail "configured login PATH is unavailable; cannot prove that $name is usable after login"
    return 1
  fi
  configured_resolved="$(PATH="$configured_path" command -v "$name" 2>/dev/null || true)"

  if [[ -z "$configured_resolved" ]]; then
    fail "$name not found in the configured login PATH"
    return 1
  fi

  if ! shell_paths_match "$configured_resolved" "$mise_resolved" &&
    ! shell_paths_match "$configured_resolved" "$mise_shim"; then
    fail "$name resolves outside mise in the configured login PATH: $configured_resolved (mise manages $mise_resolved)"
    return 1
  fi

  # The configured login PATH above is captured from an INTERACTIVE login,
  # which is the one shell where mise activation necessarily wins: the tracked
  # Zsh package activates mise in .zshrc, while .zshenv -- read by every
  # top-level Zsh, interactive or not -- puts $HOME/.local/bin first and adds
  # no mise paths. So that probe says nothing about the login where
  # ~/.local/bin wins and there are no shims at all, and a non-mise copy of a
  # tool there was reported as mise-owned (issue #396, GAP-33).
  #
  # A name that does not resolve at all in that login is the ordinary
  # shim-only case, not a defect: nothing is said about it. A caller that
  # supplies VERIFY_CONFIGURED_LOGIN_PATH by hand supplies this one too or
  # the second probe does not run.
  if [[ -n "${VERIFY_NONINTERACTIVE_LOGIN_PATH:-}" ]]; then
    login_resolved="$(PATH="$VERIFY_NONINTERACTIVE_LOGIN_PATH" \
      command -v "$name" 2>/dev/null || true)"
    if [[ -n "$login_resolved" ]] &&
      ! shell_paths_match "$login_resolved" "$mise_resolved" &&
      ! shell_paths_match "$login_resolved" "$mise_shim"; then
      fail "$name resolves outside mise in a login that is not interactive:" \
        "$login_resolved (mise manages $mise_resolved). Such a login reads" \
        ".zshenv but not .zshrc, so mise is never activated there and this" \
        "copy is what runs"
      return 1
    fi
  fi

  if shell_paths_match "$resolved" "$mise_resolved"; then
    pass "$name is mise-managed: $resolved"
  elif shell_paths_match "$resolved" "$mise_shim"; then
    pass "$name is mise-managed via shim: $resolved -> $mise_resolved"
  else
    fail "$name resolves outside mise: $resolved (mise manages $mise_resolved)"
  fi
}

# Verify the debugger provider selected by easy-dotnet.nvim. EasyDotnet's
# machine-readable health command resolves the same bundled engine/path that
# its Neovim RPC client launches. The path must never fall back to a custom or
# Mason-owned debugger, because that would bypass the declared provider.
check_easy_dotnet_debugger() {
  local expected_platform="$1"
  local health engine source platform debugger_path debugger_version_type debugger_version

  EASY_DOTNET_DEBUGGER_PATH=""

  if ! health="$(dotnet-easydotnet healthcheck --format json --debugger-engine netcoredbg 2>/dev/null)"; then
    fail "EasyDotnet debugger healthcheck failed"
    return 1
  fi

  engine="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.engine") | .value' 2>/dev/null)"
  source="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.source") | .value' 2>/dev/null)"
  platform="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.platform") | .value' 2>/dev/null)"
  debugger_path="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.path") | .value' 2>/dev/null)"
  debugger_version_type="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.version") | .type' 2>/dev/null)"
  debugger_version="$(printf '%s\n' "$health" | jq -r '.[] | select(.name == "debugger.version") | .value' 2>/dev/null)"

  if [[ "$engine" == netcoredbg ]]; then
    pass "EasyDotnet debugger engine is netcoredbg"
  else
    fail "EasyDotnet debugger engine is ${engine:-unknown}; expected netcoredbg"
  fi

  if [[ "$source" == bundled ]]; then
    pass "EasyDotnet owns the bundled debugger"
  else
    fail "EasyDotnet debugger source is ${source:-unknown}; expected bundled"
  fi

  if [[ "$platform" == "$expected_platform" ]]; then
    pass "EasyDotnet debugger platform is $expected_platform"
  else
    fail "EasyDotnet debugger platform is ${platform:-unknown}; expected $expected_platform"
  fi

  if [[ -x "$debugger_path" && "$debugger_path" == */tools/netcoredbg/"$expected_platform"/netcoredbg ]]; then
    pass "EasyDotnet bundled debugger path is executable: $debugger_path"
  else
    fail "EasyDotnet bundled debugger path is invalid or missing: ${debugger_path:-unknown}"
  fi

  if [[ "$debugger_path" == *'/nvim/mason/'* ]]; then
    fail "EasyDotnet unexpectedly resolved a Mason-owned debugger: $debugger_path"
  else
    pass "EasyDotnet debugger does not resolve through Mason"
  fi

  if [[ "$debugger_version_type" == ok && -n "$debugger_version" ]]; then
    pass "EasyDotnet debugger starts successfully: $debugger_version"
  else
    fail "EasyDotnet debugger version check is ${debugger_version_type:-missing}: ${debugger_version:-unknown}"
  fi

  export EASY_DOTNET_DEBUGGER_PATH="$debugger_path"

  ((VERIFY_FAILURES == 0))
}
