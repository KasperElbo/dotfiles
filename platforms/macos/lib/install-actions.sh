#!/usr/bin/env bash

# Argument construction for macOS install/verify actions deliberately uses the
# positional parameter vector. This remains safe with nounset even when no
# optional arguments are selected, including under Apple's Bash 3.2.
macos_run_system_installer() {
  local interactive="$1"
  if [[ "$interactive" == true ]]; then
    "$DOTFILES_ROOT/platforms/macos/scripts/install-system.sh"
  else
    "$DOTFILES_ROOT/platforms/macos/scripts/install-system.sh" --non-interactive
  fi
  activate_homebrew_path
}

macos_run_verifier() {
  local apply_defaults="$1"
  local install_containers="$2"
  local install_tailscale="$3"
  local install_dictation="${4:-false}"
  set --
  [[ "$apply_defaults" != true ]] || set -- "$@" --defaults
  [[ "$install_containers" != true ]] || set -- "$@" --containers
  [[ "$install_tailscale" != true ]] || set -- "$@" --tailscale
  [[ "$install_dictation" != true ]] || set -- "$@" --dictation
  "$DOTFILES_ROOT/platforms/macos/scripts/verify.sh" "$@"
}
