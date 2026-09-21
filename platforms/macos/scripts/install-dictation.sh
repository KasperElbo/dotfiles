#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/fetch.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"
# shellcheck source=../lib/dictation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dictation.sh"

usage() {
  cat <<'EOF'
Usage: ./platforms/macos/scripts/install-dictation.sh [options]

Install the optional local voice dictation profile: Ghost Pepper, from the
pinned upstream release disk image whose SHA-256 this repository records.

Options:
  --dry-run          Print what would be downloaded and installed, and stop
  -h, --help         Show this help

Nothing about macOS's privacy consent is scripted here. Microphone and
Accessibility access are granted by you, interactively, after the install.
EOF
}

dry_run=false
while (($#)); do
  case "$1" in
  --dry-run)
    dry_run=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
done

require_apple_silicon_macos

version="$DICTATION_GHOST_PEPPER_VERSION"
expected_sha256="$DICTATION_GHOST_PEPPER_SHA256"
release_url="$(dictation_release_url)"
app_name="$DICTATION_GHOST_PEPPER_APP"
applications_dir="$(macos_applications_dir)"
installed_app="$(dictation_installed_app)"
state_file="$(dictation_state_file)"
label="the Ghost Pepper $version disk image"

installed_version="$(dictation_installed_version "$installed_app" 2>/dev/null || true)"

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Optional macOS dictation profile plan
-------------------------------------
Application:      Ghost Pepper $version ($app_name)
Provider:         pinned upstream release disk image (no Homebrew cask exists)
Download:         $release_url
Expected SHA-256: $expected_sha256
Install path:     $installed_app
Currently installed: ${installed_version:-none}
Machine state:    $state_file
Permissions:      Microphone and Accessibility, granted by you afterwards
Never done here:  disabling Gatekeeper or SIP, and removing the quarantine
                  or code-signing attributes of the downloaded image

No changes were made.

EOF
  exit 0
fi

if [[ "$installed_version" == "$version" ]]; then
  info "Ghost Pepper $version is already installed at $installed_app"
else
  [[ -d "$applications_dir" ]] ||
    die "The applications directory does not exist: $applications_dir"
  [[ -w "$applications_dir" ]] ||
    die "Cannot write to $applications_dir; installing Ghost Pepper needs an
administrator account that owns that directory, the same way Homebrew casks do."

  work_dir="$(mktemp -d)"
  mount_point="$work_dir/volume"
  staging="$applications_dir/.dotfiles-ghost-pepper-staging.$$"
  disk_image="$work_dir/GhostPepper.dmg"
  attached=false
  mkdir -p "$mount_point"

  # Detaching is not conditional on success: a failed copy must still leave the
  # machine with no mounted image and no half-written bundle in /Applications.
  dictation_cleanup() {
    if [[ "$attached" == true ]]; then
      attached=false
      hdiutil detach "$mount_point" -quiet ||
        hdiutil detach "$mount_point" -force -quiet ||
        warn "Could not detach the Ghost Pepper disk image at $mount_point"
    fi
    # Cleared once the swap begins, so a failure between removing the old
    # bundle and moving the new one leaves the staged copy on disk rather than
    # deleting the machine's only copy of the application.
    [[ -z "$staging" ]] || rm -rf -- "$staging"
    rm -rf -- "$work_dir"
  }
  trap dictation_cleanup EXIT

  info "Downloading Ghost Pepper $version"
  # network-source: ghost-pepper-release
  fetch_to_file "$release_url" "$disk_image" "$label"
  # The digest is what makes this download trustworthy at all: upstream
  # publishes no checksum, so a mismatch means the pin is wrong or the bytes
  # are not the reviewed ones, and either way nothing may be installed.
  fetch_verify_sha256 "$disk_image" "$expected_sha256" "$label"

  info "Mounting $label"
  hdiutil attach "$disk_image" -mountpoint "$mount_point" \
    -nobrowse -readonly -noautoopen -quiet
  attached=true

  [[ -d "$mount_point/$app_name" ]] ||
    die "$label does not contain $app_name"

  # ditto, not cp: it is the tool Apple documents for copying a bundle with its
  # extended attributes and code signature intact. A signature damaged in the
  # copy would be rejected by Gatekeeper on first launch.
  info "Installing $app_name into $applications_dir"
  rm -rf -- "$staging"
  # Both paths are absolute, so there is no leading-dash ambiguity to guard
  # against and no need for a "--" terminator ditto does not document.
  ditto "$mount_point/$app_name" "$staging"
  staged_bundle="$staging"
  staging=""
  rm -rf -- "$installed_app"
  mv -- "$staged_bundle" "$installed_app" ||
    die "Could not move the staged bundle into place. It is still at
$staged_bundle; move it to $installed_app by hand, or remove it and rerun."

  dictation_cleanup
  trap - EXIT
fi

profile_state_write "$state_file" dictation installed \
  application=ghost-pepper \
  provider=upstream-dmg \
  version="$version" \
  artifact=GhostPepper.dmg \
  sha256="$expected_sha256" \
  bundle_id="$DICTATION_GHOST_PEPPER_BUNDLE_ID" \
  team_id="$DICTATION_GHOST_PEPPER_TEAM_ID" \
  path="$installed_app"

success "Optional dictation profile installed"

cat <<EOF

Ghost Pepper $version is installed at $installed_app, but it cannot dictate
anything until you open it once and approve two macOS privacy permissions.
Both prompts are interactive by design, and nothing here scripts or bypasses
them:

  1. Open Ghost Pepper (it lives in the menu bar; open it once from
     $applications_dir). Gatekeeper checks the Developer ID signature and the
     notarization ticket on that first launch -- leave Gatekeeper enabled.
  2. Microphone: approve the prompt on the first recording, or grant it in
     System Settings -> Privacy & Security -> Microphone.
  3. Accessibility: System Settings -> Privacy & Security -> Accessibility,
     then enable Ghost Pepper. This is what lets the global hold-to-talk
     hotkey be seen and the transcription be pasted into the focused
     application. Without it the hotkey does nothing.

Choose the hold-to-talk shortcut in Ghost Pepper's own settings. Avoid the
Ctrl+Option combinations AeroSpace already owns, and leave Right Option free
for macOS symbol entry.

Transcription is on-device. No account, API key or cloud provider is
configured here, and none is needed. Recordings, transcription history and
downloaded speech models stay under ~/Library and are never written into this
repository. See docs/profiles/dictation.md.

EOF
