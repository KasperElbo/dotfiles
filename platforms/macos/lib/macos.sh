#!/usr/bin/env bash

macos_kernel_name() {
  printf '%s\n' "${DOTFILES_TEST_UNAME_S:-$(uname -s)}"
}

macos_architecture() {
  printf '%s\n' "${DOTFILES_TEST_UNAME_M:-$(uname -m)}"
}

macos_is_github_hosted_runner() {
  [[ "${GITHUB_ACTIONS:-false}" == true ]] &&
    [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]
}

require_apple_silicon_macos() {
  [[ "$(macos_kernel_name)" == Darwin ]] ||
    die "The macOS profile must run on macOS."
  [[ "$(macos_architecture)" == arm64 ]] ||
    die "The macOS profile supports native Apple Silicon only (expected arm64)."

  if [[ "${DOTFILES_TEST_MACOS:-false}" != true ]] &&
    [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" == 1 ]]; then
    die "The installer is running under Rosetta; start a native arm64 terminal."
  fi
}

# macOS keeps the login shell in Directory Services rather than /etc/passwd, so
# the shared getent-based helper does not apply here.
macos_login_shell_for_user() {
  local user="$1"
  local entry

  entry="$(dscl . -read "/Users/$user" UserShell 2>/dev/null)" || return 1
  entry="${entry#UserShell:}"
  entry="${entry# }"
  [[ -n "$entry" ]] || return 1
  printf '%s\n' "$entry"
}

# Any Zsh registered in /etc/shells is supported. Apple's /bin/zsh and a
# deliberately selected Homebrew Zsh are both valid, so a compliant existing
# choice is preserved instead of being rewritten to one specific path.
macos_login_shell_is_compliant() {
  local shell_path="$1"
  local shells_file="${SHELLS_FILE:-/etc/shells}"

  [[ -n "$shell_path" ]] || return 1
  [[ "${shell_path##*/}" == zsh ]] || return 1
  [[ -r "$shells_file" ]] || return 1
  grep -Fxq "$shell_path" "$shells_file"
}

# Prefer the Zsh the workstation actually runs, falling back to Apple's. Both
# must be registered, because chsh refuses a shell missing from /etc/shells.
macos_resolve_registered_zsh() {
  local candidate

  for candidate in "$(command -v zsh 2>/dev/null || true)" /bin/zsh; do
    [[ -n "$candidate" ]] || continue
    if macos_login_shell_is_compliant "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# True when this account's login shell still has to be moved, which is the
# only reason the macOS profile needs sudo once Homebrew is present. A
# preflight has to be able to ask this *before* the run starts: "sudo chsh"
# runs in the middle of the system step, so a --non-interactive run that never
# established authorization would block there on a password prompt.
#
# An account whose shell cannot be read is treated as needing the change,
# because that is what ensure_macos_zsh_login_shell will attempt.
macos_login_shell_change_required() {
  local current_user current_shell

  current_user="$(id -un)" || return 0
  current_shell="$(macos_login_shell_for_user "$current_user")" || return 0
  ! macos_login_shell_is_compliant "$current_shell"
}

ensure_macos_zsh_login_shell() {
  local current_user
  local current_shell
  local zsh_path
  local shells_file="${SHELLS_FILE:-/etc/shells}"

  export ZSH_LOGIN_SHELL_CHANGED="false"

  [[ "$(id -u)" -ne 0 ]] ||
    die "Refusing to change root's login shell; run the installer as a regular user."

  current_user="$(id -un)" || die "Could not determine the invoking user."
  current_shell="$(macos_login_shell_for_user "$current_user")" ||
    die "Could not determine the login shell for $current_user."

  if macos_login_shell_is_compliant "$current_shell"; then
    info "Zsh is already the default login shell: $current_shell"
    return 0
  fi

  zsh_path="$(macos_resolve_registered_zsh)" ||
    die "No Zsh is registered in $shells_file; cannot set a supported login shell."

  info "Setting Zsh as the default login shell: $zsh_path"
  sudo chsh -s "$zsh_path" "$current_user"
  current_shell="$(macos_login_shell_for_user "$current_user")" ||
    die "Could not verify the updated login shell for $current_user."
  macos_login_shell_is_compliant "$current_shell" ||
    die "Account login shell did not change to a registered Zsh: ${current_shell:-unknown}"
  export ZSH_LOGIN_SHELL_CHANGED="true"
}

homebrew_path() {
  printf '%s\n' "${HOMEBREW_BIN:-/opt/homebrew/bin/brew}"
}

# The directory macOS keeps applications in. A real run never sets the
# override; it exists so the one profile that writes an application bundle
# itself, rather than handing the job to Homebrew, can be exercised against a
# fixture directory the way HOMEBREW_BIN and SHELLS_FILE already allow.
macos_applications_dir() {
  printf '%s\n' "${MACOS_APPLICATIONS_DIR:-/Applications}"
}

activate_homebrew_path() {
  export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
}

require_native_homebrew() {
  local brew_bin
  local prefix

  brew_bin="$(homebrew_path)"
  [[ -x "$brew_bin" ]] || die "Native Homebrew is not installed at $brew_bin."
  prefix="$($brew_bin --prefix)"
  [[ "$prefix" == /opt/homebrew ]] ||
    die "Expected Apple Silicon Homebrew prefix /opt/homebrew, got: $prefix"
}

# ---------------------------------------------------------------------------
# Desktop wallpaper
#
# The interface is `osascript` telling System Events to set the picture of
# every desktop, which is the one documented automation surface Apple offers
# for this. The alternatives were rejected deliberately: writing
# ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist or the
# older desktoppicture.db is undocumented manipulation of a system database
# that a macOS release may change without notice, and it is the kind of thing
# that fails silently rather than loudly.
#
# What it depends on, so that a future macOS breaking it is diagnosable:
#
#   - Apple Events automation permission. The process running `theme` must be
#     allowed to control System Events (System Settings > Privacy & Security >
#     Automation). The first run prompts; a denied or unapproved caller gets
#     osascript error -1743, which macos_set_wallpaper reports as itself
#     rather than as a generic failure.
#   - System Events itself, and the `picture` property of its `desktop`
#     objects. That property is what a macOS release would remove.
#   - The image existing at the path given, readable by the user.
#
# Multi-display and Spaces, decided rather than left to be discovered:
# `every desktop` is every attached display, so all displays change together.
# AppleScript exposes one desktop object per display and none per Space, so
# the change lands on each display's current Space. A Space that carries its
# own wallpaper keeps it, and a Space created afterwards takes whatever macOS
# gives a new Space. Per-display wallpapers are not offered; this repository
# applies one flavour to the whole desktop.
# ---------------------------------------------------------------------------

# macos_wallpaper_for_flavour <flavour>: the stowed asset for that flavour.
# One copy of each image, from the shared theme-assets package.
macos_wallpaper_for_flavour() {
  printf '%s/.local/share/wallpapers/catppuccin-%s.webp\n' "$HOME" "$1"
}

# macos_set_wallpaper <path>: point every display at that image.
macos_set_wallpaper() {
  local path="$1" output status=0

  [[ -r "$path" ]] || {
    printf 'Wallpaper is missing or unreadable: %s\n' "$path" >&2
    return 1
  }
  command_exists osascript || {
    printf 'osascript is unavailable; cannot set the desktop wallpaper.\n' >&2
    return 1
  }

  output="$(
    osascript -e 'on run argv
  tell application "System Events" to set picture of every desktop to (item 1 of argv)
end run' -- "$path" 2>&1
  )" || status=$?

  ((status == 0)) || {
    # -1743 is "not authorised to send Apple events", which is a permission to
    # grant rather than a bug to report, so it is named.
    if [[ "$output" == *-1743* ]]; then
      printf 'Not permitted to control System Events, so the wallpaper was not changed.\n' >&2
      printf 'Allow it in System Settings > Privacy & Security > Automation for the program running "theme", then run "theme" again.\n' >&2
    else
      printf 'Setting the desktop wallpaper failed: %s\n' "${output:-no output}" >&2
    fi
    return "$status"
  }
}
