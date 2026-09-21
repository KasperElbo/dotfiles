#!/usr/bin/env bash

# Shared read-only verification primitives.
#
# This library deliberately does not select shell options. Verifier entrypoints
# own their execution policy; sourcing a common library must never change the
# caller's errexit, nounset, or pipefail state. It needs version_at_least from
# lib/common.sh, and sources that itself when the caller has not.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

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

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
  VERIFY_PASSES=$((VERIFY_PASSES + 1))
  return 0
}

fail() {
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

check_file_contains() {
  local label="$1"
  local path="$2"
  local expected="$3"

  if [[ -r "$path" ]] && grep -Fq -- "$expected" "$path"; then
    pass "$label"
  else
    fail "$label: expected '$expected' in $path"
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

check_file_mode() {
  local label="$1"
  local path="$2"
  local expected_mode="$3"
  local actual_mode

  actual_mode="$(verify_file_mode "$path" 2>/dev/null || true)"
  if [[ "$actual_mode" == "$expected_mode" ]]; then
    pass "$label mode is $expected_mode"
  else
    fail "$label mode is ${actual_mode:-unknown}; expected $expected_mode"
  fi
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

# check_symlink <link> <expected-root>
#
# An owned Stow link has five independent properties: the link object exists,
# it is a symlink, its referent exists, canonical resolution succeeds, and the
# resolved referent is inside the exact expected package root. The final test
# is component-aware so /repo/dotfiles-other never satisfies /repo/dotfiles.
check_symlink() {
  local link="$1"
  local expected_root="${2%/}"
  local resolved=""
  local canonical_root=""

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

  if verify_path_is_within_root "$resolved" "$canonical_root"; then
    pass "$link -> $resolved"
    return 0
  fi

  fail "$link is not owned by the expected package; resolved=$resolved expected=$canonical_root"
  return 1
}

check_system_service_active() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    pass "$unit is active"
  else
    fail "$unit is not active"
  fi
}

check_user_service_active() {
  local unit="$1"
  if systemctl --user is-active --quiet "$unit"; then
    pass "$unit is active for the user"
  else
    fail "$unit is not active for the user"
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

# check_mason_inventory <inventory>
#
# Every package the tracked Mason inventory lists must be installed under
# Mason's package root. A package Mason holds that the inventory does not list
# is a warning rather than a failure: it may be a deliberate local addition,
# but nothing in this repository owns it.
check_mason_inventory() {
  local inventory="$1"
  local mason_root="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason/packages"
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
  # with a loop instead. The sed is unchanged, so the comment and blank-line
  # filtering and the package order are exactly what they were. Its output is
  # captured rather than read through a process substitution so its status
  # survives: the guards above cover every read failure that can be produced on
  # demand, and this covers the residual one, an I/O error part-way through a
  # file that was a readable regular file when it was tested. The empty-string
  # guard below is needed because a here-string of "" still yields one empty
  # line.
  filtered="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$inventory")" || {
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

  for package in "${packages[@]}"; do
    if [[ -d "$mason_root/$package" ]]; then
      pass "Mason: $package"
    else
      fail "Mason package not installed: $package"
      status=1
    fi
  done

  for package_dir in "$mason_root"/*; do
    [[ -d "$package_dir" ]] || continue
    package="${package_dir##*/}"
    for listed in "${packages[@]}"; do
      [[ "$package" != "$listed" ]] || continue 2
    done
    warning "Unexpected Mason package (review ownership): $package"
  done
  return "$status"
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
  if ((status != 0)); then
    not_observed "npm is not runnable under mise; cannot rule out a duplicate" \
      "AI package in the active Node prefix"
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

  [[ "$duplicate" == true ]] ||
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

check_mise_owned() {
  local name="$1"
  local resolved mise_resolved mise_shim configured_path configured_resolved mise_command
  local mise_data_dir mise_shims_dir

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
