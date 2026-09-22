#!/usr/bin/env bash

# The pinned Ghost Pepper artifact, shared by the installer and the verifier.
#
# Sourcing this file intentionally sets no shell options and calls nothing: it
# is a set of constants plus a few small readers, so the script that installs
# the application and the verifier that proves it is installed can never
# disagree about which release, which digest, or which signing identity is
# expected, and the installer's preflight and its own guard can never disagree
# about who may install it.
#
# Why a pinned disk image rather than a package manager
# -----------------------------------------------------
# Ghost Pepper has no Homebrew cask, so it cannot be declared in
# platforms/macos/Brewfile like every other macOS application this repository
# owns. The alternative to an unpinned "download the latest build" path is the
# mechanism this repository already uses for the Hack Nerd Font: an exact
# release URL plus a SHA-256 this repository computed and recorded. Upstream
# publishes no checksum file, so the digest below was computed here from the
# downloaded asset and is what makes the download verifiable at all.
#
# Bumping the pin is therefore a reviewed act. See docs/profiles/dictation.md
# and the ghost-pepper-release row in config/network-sources.tsv.

# The upstream release tag, without its leading "v".
DICTATION_GHOST_PEPPER_VERSION="2.4.4"

# SHA-256 of that release's GhostPepper.dmg, computed in this repository.
# shellcheck disable=SC2034 # Read by the installer that sources this file.
DICTATION_GHOST_PEPPER_SHA256="a8c09b24ce19613bb421c0dce06e6167d738a8295f05fa5e5a363551de6b8f06"

# The Apple Developer ID team the application is signed with. Verification
# asserts this rather than merely "is signed", so a differently signed build
# under the same name fails loudly instead of being accepted.
# shellcheck disable=SC2034 # Read by the verifier that sources this file.
DICTATION_GHOST_PEPPER_TEAM_ID="BBVMGXR9AY"

# The bundle installed into the applications directory, and its identifier.
DICTATION_GHOST_PEPPER_APP="GhostPepper.app"
# shellcheck disable=SC2034 # Read by the installer that sources this file.
DICTATION_GHOST_PEPPER_BUNDLE_ID="com.github.matthartman.ghostpepper"

# Where this profile records what it installed.
DICTATION_STATE_RELATIVE_PATH="dotfiles/macos-dictation.conf"

# The bound, in seconds, on the Gatekeeper assessment the verifier makes. An
# assessment may consult Apple's notarization service, so it is a call to
# another process over the network and gets a bound like every other one.
# Overridable so a test can drive it without waiting.
: "${DOTFILES_DICTATION_ASSESS_TIMEOUT:=20}"

# dictation_release_url: the exact release asset this profile installs. The URL
# is built from the pinned tag so the tag cannot drift from the download.
dictation_release_url() {
  local ghost_pepper_version="$DICTATION_GHOST_PEPPER_VERSION"
  printf 'https://github.com/matthartman/ghost-pepper/releases/download/v%s/GhostPepper.dmg\n' \
    "$ghost_pepper_version"
}

# dictation_state_file: the machine-local state file for this profile.
dictation_state_file() {
  printf '%s/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$DICTATION_STATE_RELATIVE_PATH"
}

# dictation_installed_app: the installed bundle's path.
dictation_installed_app() {
  printf '%s/%s\n' "$(macos_applications_dir)" "$DICTATION_GHOST_PEPPER_APP"
}

# dictation_installed_version <bundle>: the short version string of an
# installed bundle, or a non-zero status when there is nothing to read. macOS
# keeps this in the bundle's Info.plist; `defaults read` is the reader every
# supported macOS ships, and the one this repository already uses elsewhere.
dictation_installed_version() {
  local plist="$1/Contents/Info.plist" version

  [[ -f "$plist" ]] || return 1
  version="$(defaults read "${plist%.plist}" CFBundleShortVersionString 2>/dev/null)" ||
    return 1
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

# dictation_pinned_build_installed: true when the installed bundle is already
# the pinned release. That is the one case in which installing writes nothing
# into the applications directory, so it is the one case that needs no access
# to it.
dictation_pinned_build_installed() {
  local installed

  installed="$(dictation_installed_version "$(dictation_installed_app)" 2>/dev/null)" ||
    return 1
  [[ "$installed" == "$DICTATION_GHOST_PEPPER_VERSION" ]]
}

# dictation_require_applications_dir <directory>: return when this account can
# write the bundle into <directory>, and stop through die otherwise. Needs die
# from common/lib/common.sh.
#
# The test is the kernel's own answer for this process, `-w`, asked before
# anything is downloaded, mounted or staged: an account that cannot write there
# is refused cleanly instead of leaving a staging copy or half a bundle behind.
# The installer asks it twice, as a plan preflight before any step runs and
# again inside the step, because the answer can change in between.
#
# The refusal names the account, the directory's owner, group and mode, and the
# check that answers whether the account is an administrator. The answer
# depends on the directory service at the moment of asking, not on anything
# this repository sets: on a Mac whose administrator rights are granted for a
# limited time, the same account is refused before that grant takes effect and
# passes after it, which a message without those inputs cannot explain.
dictation_require_applications_dir() {
  local directory="$1" account mode owner group

  [[ -d "$directory" ]] ||
    die "The applications directory does not exist: $directory"
  [[ ! -w "$directory" ]] || return 0

  account="$(id -un)"
  read -r mode _ owner group _ <<<"$(ls -ld "$directory")"
  die "Cannot write to $directory as $account, so Ghost Pepper cannot be
installed; nothing was downloaded or installed. The directory is $owner:$group,
$mode. On a standard Mac /Applications is root:admin, drwxrwxr-x, so writing
there takes membership of the admin group; check this account with:
  dseditgroup -o checkmember -m $account admin
If this Mac grants administrator rights only for a limited time, start that
elevation, wait until the check above answers yes, and then rerun."
}

# dictation_preflight: the dictation step's plan preflight. Ghost Pepper is the
# one application this profile copies into the applications directory itself,
# so whether this account may write there is decided before any step runs,
# rather than discovered after the steps ahead of it have finished. A machine
# that already has the pinned build writes nothing there and is not asked.
dictation_preflight() {
  dictation_pinned_build_installed ||
    dictation_require_applications_dir "$(macos_applications_dir)"
}
