#!/usr/bin/env bash

macos_kernel_name() {
  printf '%s\n' "${DOTFILES_TEST_UNAME_S:-$(uname -s)}"
}

macos_architecture() {
  printf '%s\n' "${DOTFILES_TEST_UNAME_M:-$(uname -m)}"
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

homebrew_path() {
  printf '%s\n' "${HOMEBREW_BIN:-/opt/homebrew/bin/brew}"
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
