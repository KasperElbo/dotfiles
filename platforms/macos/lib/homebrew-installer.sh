#!/bin/bash

# The pinned Homebrew installer, shared by scripts/bootstrap-macos.sh and
# platforms/macos/scripts/install-system.sh.
#
# Apple's Bash 3.2 sources this file before any other repository library
# exists, so it is limited to that dialect, sets no shell options and depends
# on nothing but curl and shasum, both part of macOS.
#
# The installer used to be fetched from the moving HEAD of Homebrew/install and
# run as it was served that minute, with root privileges through sudo (#504).
# It is now fetched at one reviewed commit and refused unless its SHA-256 is
# the one below, before anything executes it. What it then installs, Homebrew
# itself from github.com/Homebrew/brew, is Homebrew's own trust root, as every
# later `brew update` is.
#
# Bumping the pin is a reviewed edit of both values together: read the new
# commit's install.sh, then take its digest with
#   curl -fsSL https://raw.githubusercontent.com/Homebrew/install/<commit>/install.sh | shasum -a 256
# ./scripts/check-pin-freshness.sh reports when upstream's default branch has
# moved past the pinned commit.
DOTFILES_HOMEBREW_INSTALLER_COMMIT="e53db71afc381d41c46c8baaeba10c091acf4b44"
DOTFILES_HOMEBREW_INSTALLER_SHA256="f31a38f097f3b5bbfdc110658e4a9876d0c023ccc9ef2e70527f5b8a762e505e"

# homebrew_installer_url: the pinned installer's immutable address.
homebrew_installer_url() {
  # network-source: homebrew-installer
  printf 'https://raw.githubusercontent.com/Homebrew/install/%s/install.sh\n' \
    "$DOTFILES_HOMEBREW_INSTALLER_COMMIT"
}

# homebrew_installer_verify <file>: succeeds only when the file's SHA-256 is
# the pinned one, and says what it found otherwise.
homebrew_installer_verify() {
  homebrew_installer_actual="$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)"
  if [ "$homebrew_installer_actual" = "$DOTFILES_HOMEBREW_INSTALLER_SHA256" ]; then
    return 0
  fi
  printf 'ERROR: SHA-256 mismatch for the Homebrew installer at commit %s: expected %s, got %s; nothing was executed.\n' \
    "$DOTFILES_HOMEBREW_INSTALLER_COMMIT" "$DOTFILES_HOMEBREW_INSTALLER_SHA256" \
    "${homebrew_installer_actual:-no digest}" >&2
  return 1
}
