#!/usr/bin/env bash

# Libraries that need this one source it themselves when this marker is unset,
# so sourcing them standalone works and a second source is a no-op that cannot
# reset a DOTFILES_ROOT or XDG value the caller already adjusted.
# shellcheck disable=SC2034
DOTFILES_COMMON_LOADED=true

# Shared library value consumed by sourcing scripts.
# shellcheck disable=SC2034
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"

info() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m==>\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prepend_path() {
  local entry="$1"
  local current
  local rebuilt=""
  local -a path_entries=()

  [[ -n "$entry" ]] || return 0

  IFS=: read -r -a path_entries <<<"${PATH:-}"
  for current in "${path_entries[@]}"; do
    [[ -n "$current" && "$current" != "$entry" ]] || continue
    rebuilt="${rebuilt:+$rebuilt:}$current"
  done

  PATH="$entry${rebuilt:+:$rebuilt}"
  export PATH
}

append_path() {
  local entry="$1"
  local current
  local rebuilt=""
  local -a path_entries=()

  [[ -n "$entry" ]] || return 0

  IFS=: read -r -a path_entries <<<"${PATH:-}"
  for current in "${path_entries[@]}"; do
    [[ -n "$current" && "$current" != "$entry" ]] || continue
    rebuilt="${rebuilt:+$rebuilt:}$current"
  done

  PATH="${rebuilt:+$rebuilt:}$entry"
  export PATH
}

resolve_mise_command() {
  local candidate

  # The standalone Linux installer has a fixed, user-owned location. Prefer
  # it before inherited PATH so a stale WSL process cannot select mise.exe.
  if [[ -x "$HOME/.local/bin/mise" ]]; then
    printf '%s\n' "$HOME/.local/bin/mise"
  else
    candidate="$(command -v mise 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
    else
      return 1
    fi
  fi
}

# --- Deterministic mise invocation ------------------------------------------
#
# mise composes its configuration from the global config *and* from every
# mise.toml/.mise.toml between the working directory and the filesystem root.
# A dotfiles bootstrap started from inside an unrelated project would therefore
# install that project's tools, or let them influence resolution.
#
# Every mise call this repository makes runs instead from an empty,
# repository-owned context directory, with MISE_CEILING_PATHS set to that same
# directory. MISE_CEILING_PATHS is mise's own supported mechanism and stops the
# ancestry walk there, excluding the ceiling directory itself; the neutral
# working directory gives the same guarantee on a mise too old to know the
# setting. The global config (and its conf.d fragments) still applies, which is
# exactly the manifest a global bootstrap is meant to install.

mise_context_dir() {
  printf '%s/dotfiles/mise-context\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# mise_config_summary: the logical manifest a deterministic invocation applies.
# Printed in verbose/dry-run output so it is obvious which config is in play.
mise_config_summary() {
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

  printf 'global: %s/mise/config.toml\n' "$config_home"
  printf 'fragments: %s/mise/conf.d/*.toml\n' "$config_home"
  printf 'directory config: none (context %s, MISE_CEILING_PATHS set to it)\n' \
    "$(mise_context_dir)"
}

mise_prepare_context() {
  local context
  local stray

  context="$(mise_context_dir)"
  ensure_dir "$context"

  # This directory is repository-owned and must stay free of tool declarations;
  # a stray config here would silently defeat the isolation it exists to give.
  for stray in mise.toml .mise.toml mise.local.toml .mise.local.toml; do
    [[ ! -e "$context/$stray" ]] || rm -f -- "$context/$stray"
  done

  printf '%s\n' "$context"
}

# run_mise <mise-executable> [arguments...]: invoke mise in the deterministic
# context. Use this for every install, resolution, and verification call so a
# caller's project configuration can never reach a global bootstrap.
run_mise() {
  local mise_command="$1"
  local context
  shift

  context="$(mise_prepare_context)" || return 1

  (
    cd -- "$context" || exit 1
    MISE_CEILING_PATHS="$context" exec "$mise_command" "$@"
  )
}

# Establish the non-interactive equivalent of the user-tool portion of the
# final Zsh environment. Installers must not rely on the shell which launched
# them having sourced .zshenv/.zshrc (notably, a WSL terminal may still be the
# Bash process from before ensure_zsh_login_shell changed the account).
establish_user_tool_environment() {
  local mise_data_dir
  local mise_shims_dir

  mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
  mise_shims_dir="${MISE_SHIMS_DIR:-$mise_data_dir/shims}"

  prepend_path "$HOME/.local/bin"
  prepend_path "$mise_shims_dir"
  hash -r 2>/dev/null || true
}

ensure_dir() {
  mkdir -p "$1"
}

# resolve_existing_path <path>: the path an existing file ultimately names,
# with every symlink in the chain followed and the directory canonicalized.
# Basic readlink is all this uses, because macOS only grew 'readlink -f' in
# recent releases and this repository supports Apple's tools as shipped.
# Fails when the path does not exist, when a link dangles, or when the chain
# loops; the bound is explicit rather than left to the kernel.
resolve_existing_path() {
  local path="$1"
  local target directory name iteration=0

  [[ -e "$path" || -L "$path" ]] || return 1

  while [[ -L "$path" ]]; do
    iteration=$((iteration + 1))
    ((iteration <= 64)) || return 1
    target="$(readlink "$path" 2>/dev/null)" || return 1
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      path="$(dirname "$path")/$target"
    fi
    [[ -e "$path" || -L "$path" ]] || return 1
  done

  [[ -e "$path" ]] || return 1
  directory="$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd)" || return 1
  name="$(basename -- "$path")"
  [[ -e "$directory/$name" ]] || return 1

  # Joining '/' with a child using the generic '%s/%s' form produces '//usr'.
  # Although POSIX permits a special interpretation for exactly two leading
  # slashes, verifier ownership checks need one stable canonical spelling.
  if [[ "$directory" == / ]]; then
    printf '/%s\n' "${name#/}"
  else
    printf '%s/%s\n' "$directory" "$name"
  fi
}

resolve_symlink_target() {
  local path="$1"
  local target
  local target_dir

  target="$(readlink "$path")" || return 1

  if [[ "$target" != /* ]]; then
    target="$(dirname "$path")/$target"
  fi

  target_dir="$(cd -P "$(dirname "$target")" 2>/dev/null && pwd)" || return 1
  printf '%s/%s\n' "$target_dir" "$(basename "$target")"
}

atomic_write_file() {
  local path="$1"
  local temporary

  [[ ! -d "$path" ]] || die "Cannot replace directory with file: $path"

  ensure_dir "$(dirname "$path")"
  chmod 700 "$(dirname "$path")" 2>/dev/null || true
  temporary="$(mktemp "${path}.XXXXXX")"

  if ! cat >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi

  chmod 600 "$temporary"

  # Persist the temporary file before the same-filesystem rename when the
  # host supplies GNU sync. macOS sync has no -f, so durability there relies
  # on rename semantics rather than turning a safe write into a hard failure.
  sync -f "$temporary" 2>/dev/null || true

  if ! mv -- "$temporary" "$path"; then
    rm -f -- "$temporary"
    return 1
  fi
}

# confirm <prompt> [default]: ask a yes/no question. The default is "y" or
# "n" (no second argument means "n"), it decides what pressing Enter means,
# and the rendered hint is derived from it, so the prompt can never advertise
# one default while applying another.
#
# Exit status is three-valued on purpose: 0 yes, 1 no, 2 unparseable answer.
# A caller distinguishes "the user declined" from "the user typed something
# nobody can interpret", and no answer is ever guessed.
confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local hint
  local answer
  local normalized

  case "$default" in
  y | Y | yes | YES) default=y; hint='[Y/n]' ;;
  n | N | no | NO) default=n; hint='[y/N]' ;;
  *) die "confirm: default must be y or n, got: $default" ;;
  esac

  # The question is written here rather than passed to "read -p", which shows
  # nothing unless standard input is a terminal: the prompt and the default it
  # advertises are part of the contract, so they belong in the transcript of
  # every run that asks, piped or not.
  printf '%s %s ' "$prompt" "$hint" >&2
  # A closed standard input is not an answer, so the default is deliberately
  # not applied to it: an unattended run must not be able to inherit a yes it
  # never typed. Declining is the safe reading, and a run that means "do not
  # prompt" passes --non-interactive instead.
  if ! read -r answer; then
    printf '\n' >&2
    warn 'No answer is available on standard input; treating the prompt as declined.'
    return 1
  fi
  [[ -n "$answer" ]] || answer="$default"

  normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
  y | yes) return 0 ;;
  n | no) return 1 ;;
  *)
    warn "Invalid response '$answer'; expected yes or no."
    return 2
    ;;
  esac
}

require_regular_user() {
  [[ "$(id -u)" -ne 0 ]] ||
    die "Refusing to run the user installer as root; run it as a regular user."
}

preflight_sudo() {
  local interactive="${1:-true}"

  require_command sudo
  if [[ "$interactive" == "true" ]]; then
    sudo -v || die "Could not acquire sudo authorization before installation."
  else
    sudo -n -v ||
      die "Non-interactive installation requires cached sudo authorization; run 'sudo -v' first."
  fi
}

require_command() {
  command_exists "$1" || die "Required command not found: $1"
}

login_shell_for_user() {
  local user="$1"
  local passwd_entry

  passwd_entry="$(getent passwd "$user")" || return 1
  printf '%s\n' "${passwd_entry##*:}"
}

resolve_zsh_path() {
  local zsh_path

  zsh_path="$(command -v zsh 2>/dev/null)" || return 1
  [[ "$zsh_path" == /* && -f "$zsh_path" && -x "$zsh_path" ]] || return 1
  printf '%s\n' "$zsh_path"
}

shell_paths_match() {
  local first="$1"
  local second="$2"

  [[ -n "$first" && -n "$second" ]] || return 1
  [[ "$first" == "$second" ]] ||
    [[ -e "$first" && -e "$second" && "$first" -ef "$second" ]]
}

ensure_zsh_login_shell() {
  local current_user
  local current_shell
  local zsh_path
  local shells_file="${SHELLS_FILE:-/etc/shells}"

  export ZSH_LOGIN_SHELL_CHANGED="false"

  [[ "$(id -u)" -ne 0 ]] ||
    die "Refusing to change root's login shell; run the installer as a regular user."

  current_user="$(id -un)" || die "Could not determine the invoking user."
  current_shell="$(login_shell_for_user "$current_user")" ||
    die "Could not determine the login shell for $current_user."
  zsh_path="$(resolve_zsh_path)" || die "Could not resolve an installed Zsh executable."
  if [[ "${REQUIRE_REGISTERED_LOGIN_SHELL:-false}" == "true" ]]; then
    [[ -r "$shells_file" ]] || die "Cannot read the login-shell registry: $shells_file"
    grep -Fxq "$zsh_path" "$shells_file" ||
      die "Resolved Zsh is not registered in $shells_file: $zsh_path"
  fi

  if shell_paths_match "$current_shell" "$zsh_path"; then
    info "Zsh is already the default login shell"
  else
    info "Setting Zsh as the default login shell"
    sudo usermod --shell "$zsh_path" "$current_user"
    current_shell="$(login_shell_for_user "$current_user")" ||
      die "Could not verify the updated login shell for $current_user."
    shell_paths_match "$current_shell" "$zsh_path" ||
      die "Account login shell did not change to $zsh_path."
    export ZSH_LOGIN_SHELL_CHANGED="true"
  fi
}
