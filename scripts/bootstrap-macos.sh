#!/bin/bash

# Apple ships Bash 3.2. This file is intentionally limited to that dialect and
# performs only the work required to reach a supported modern Bash.
set -e

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
real_installer="$repo_root/scripts/install-main.sh"
minimum_bash="4.4"

bash_is_supported() {
  candidate="$1"
  [ -x "$candidate" ] || return 1
  "$candidate" -c \
    '((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)))' \
    >/dev/null 2>&1
}

exec_real_installer() {
  candidate="$1"
  shift
  candidate_dir="$(dirname "$candidate")"
  PATH="$candidate_dir:$PATH"
  export PATH
  if [ "${DOTFILES_BOOTSTRAP_TRACE:-false}" = "true" ]; then
    printf 'macOS bootstrap: re-executing with %s\n' "$candidate" >&2
  fi
  exec "$candidate" "$real_installer" "$@"
}

if bash_is_supported "${BASH:-}"; then
  candidate="$BASH"
  exec_real_installer "$candidate" "$@"
fi

help_requested="false"
dry_run="false"
non_interactive="false"
for argument in "$@"; do
  case "$argument" in
    -h|--help) help_requested="true" ;;
    --dry-run) dry_run="true" ;;
    --non-interactive) non_interactive="true" ;;
  esac
done

brew_bin="${HOMEBREW_BIN:-}"
if [ -z "$brew_bin" ] && [ -n "${HOMEBREW_PREFIX:-}" ]; then
  brew_bin="$HOMEBREW_PREFIX/bin/brew"
fi
if [ -z "$brew_bin" ] && [ -x /opt/homebrew/bin/brew ]; then
  brew_bin="/opt/homebrew/bin/brew"
fi

homebrew_bash=""
if [ -n "$brew_bin" ] && [ -x "$brew_bin" ]; then
  brew_prefix="$($brew_bin --prefix 2>/dev/null || true)"
  if [ "$brew_prefix" != "/opt/homebrew" ]; then
    printf 'ERROR: The Apple Silicon profile requires native Homebrew at /opt/homebrew; found %s.\n' \
      "${brew_prefix:-an unreadable prefix}" >&2
    exit 1
  fi
  bash_prefix="$($brew_bin --prefix bash 2>/dev/null || true)"
  if [ -n "$bash_prefix" ]; then
    homebrew_bash="$bash_prefix/bin/bash"
  fi
fi

if [ -n "$homebrew_bash" ] && bash_is_supported "$homebrew_bash"; then
  exec_real_installer "$homebrew_bash" "$@"
fi

if [ "$help_requested" = "true" ]; then
  # shellcheck source=../platforms/macos/lib/usage.sh
  . "$repo_root/platforms/macos/lib/usage.sh"
  macos_usage
  printf '\nBootstrap note: applying this profile first establishes Homebrew Bash %s+; --help never changes the machine.\n' \
    "$minimum_bash"
  exit 0
fi

if [ "$dry_run" = "true" ]; then
  if [ -n "$brew_bin" ] && [ -x "$brew_bin" ]; then
    homebrew_state="present"
  else
    homebrew_state="would be installed"
  fi
  cat <<EOF
macOS compatibility bootstrap plan
----------------------------------
Required interpreter: Homebrew Bash $minimum_bash or newer
Homebrew:             $homebrew_state
Homebrew Bash:        would be installed

The Homebrew/Bash compatibility bootstrap is explicitly outside the normal
installation lifecycle because that lifecycle itself requires modern Bash.
After the interpreter exists, the same command renders the complete #185
preflight and execution plan. No changes were made.
EOF
  exit 0
fi

kernel_name="$(uname -s)"
architecture="$(uname -m)"
if [ "$kernel_name" != "Darwin" ]; then
  printf 'ERROR: The macOS bootstrap must run on macOS.\n' >&2
  exit 1
fi
if [ "$architecture" != "arm64" ]; then
  printf 'ERROR: The macOS profile supports native Apple Silicon only (expected arm64).\n' >&2
  exit 1
fi
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || printf '0')" = "1" ]; then
  printf 'ERROR: The installer is running under Rosetta; start a native arm64 terminal.\n' >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  printf "ERROR: Apple Command Line Tools are required; run 'xcode-select --install', finish the dialog, then rerun.\n" >&2
  exit 1
fi

printf 'The compatibility bootstrap must establish Homebrew Bash before the normal installation plan can run.\n'
printf 'This may install native Homebrew and will install the Homebrew bash formula.\n'

if [ -z "$brew_bin" ] || [ ! -x "$brew_bin" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    printf 'ERROR: curl is required to install Homebrew.\n' >&2
    exit 1
  fi
  if [ "$non_interactive" = "true" ]; then
    if ! command -v sudo >/dev/null 2>&1 || ! sudo -n -v; then
      printf "ERROR: Non-interactive Homebrew bootstrap requires cached sudo authorization; run 'sudo -v' first.\n" >&2
      exit 1
    fi
  fi

  installer="$(mktemp -t dotfiles-homebrew-bootstrap.XXXXXX)"
  trap 'rm -f "$installer"' EXIT
  # This entry point runs under Apple's Bash 3.2 before any repository library
  # is available, so the bounded-transfer policy from common/lib/fetch.sh is
  # written out here instead of being sourced.
  # network-source: homebrew-installer
  curl --fail --location --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 120 \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
    --output "$installer"
  if [ ! -s "$installer" ]; then
    printf 'ERROR: The Homebrew installer download was empty; nothing was executed.\n' >&2
    exit 1
  fi
  if [ "$non_interactive" = "true" ]; then
    NONINTERACTIVE=1 /bin/bash "$installer"
  else
    /bin/bash "$installer"
  fi
  rm -f "$installer"
  trap - EXIT
  brew_bin="/opt/homebrew/bin/brew"
fi

if [ ! -x "$brew_bin" ]; then
  printf 'ERROR: Homebrew bootstrap completed without creating /opt/homebrew/bin/brew.\n' >&2
  exit 1
fi

"$brew_bin" install bash
bash_prefix="$($brew_bin --prefix bash)"
homebrew_bash="$bash_prefix/bin/bash"
if ! bash_is_supported "$homebrew_bash"; then
  printf 'ERROR: Homebrew did not provide a working Bash %s+ at %s.\n' \
    "$minimum_bash" "$homebrew_bash" >&2
  exit 1
fi

exec_real_installer "$homebrew_bash" "$@"
