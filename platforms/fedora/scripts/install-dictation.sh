#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/fetch.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/dictation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dictation.sh"

dry_run="false"

# The Fedora-owned half of the profile. wtype is the Wayland virtual-keyboard
# client Handy types the transcription through, and gtk-layer-shell is the
# runtime library Handy links against and fails to start without. Both are
# plain Fedora packages, so dnf owns them; nothing here needs /dev/uinput or
# the `input` group, because that is only the `dotool` path and this profile
# does not use it.
packages=(
  gtk-layer-shell
  wtype
)

# The pinned Handy release, the artifact it publishes and the digest that
# stands in for the RPM signature upstream does not ship, all read from the one
# file the verifier reads them from too. Bumping the pin means editing
# platforms/fedora/lib/dictation.sh and nothing else; see
# docs/profiles/dictation.md, "Bumping the pinned Handy release".
handy_version="$(dictation_pinned_version)"
handy_rpm="$(dictation_pinned_rpm)"
handy_url="$(dictation_release_url)"
handy_rpm_sha256="$(dictation_pinned_sha256)"

state_file="${DICTATION_STATE_FILE:-$(dictation_state_file)}"

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-dictation.sh [options]

Install the optional voice-dictation profile: Handy, a local-only
speech-to-text application, plus the two Fedora packages it needs on Wayland
(wtype for text insertion, gtk-layer-shell as a runtime library).

Handy is installed from a version-pinned upstream release .rpm whose SHA-256
is recorded in platforms/fedora/lib/dictation.sh. Transcription is local and offline: no account,
no API key, and no cloud endpoint is configured by this profile.

The dictation key is owned by Sway, not by Handy: the tracked Sway config
binds Super+O to 'pkill -USR2 -x handy', because an application-global
shortcut cannot work on a wlroots compositor.

Options:
  --dry-run   Show the dictation plan without changing anything
  -h, --help  Show this help
EOF
}

while (($#)); do
  case "$1" in
  --dry-run)
    dry_run="true"
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

pin_is_recorded() {
  dictation_pin_is_recorded
}

# Why the machine is asked rather than only the state file
# --------------------------------------------------------
# The state file is this profile's own record of what it did, so on its own it
# proves only that the profile once ran. Skipping work on that alone meant a
# machine whose Handy rpm had been removed, downgraded or replaced by an
# unpackaged build still reported "already installed from the pinned artifact"
# and repaired nothing, because a file called handy existed somewhere on PATH.
#
# So the fast path now asks the rpm database, which is the machine's own record
# rather than this profile's: the binary on PATH must be owned by an rpm whose
# name-version-release.arch is the pinned artifact's, and the Wayland packages
# the profile declares must still be installed. Anything else is drift, and
# drift falls through to the install below, which reinstalls the dependencies
# and the pinned rpm and rewrites the state. That is the repair.
installed_matches_pin() {
  local recorded_version recorded_sha handy_path owning_nvra package

  [[ -f "$state_file" ]] || return 1
  recorded_version="$(profile_state_read "$state_file" version dictation 2>/dev/null)" || return 1
  recorded_sha="$(profile_state_read "$state_file" sha256 dictation 2>/dev/null)" || return 1
  [[ "$recorded_version" == "$handy_version" && "$recorded_sha" == "$handy_rpm_sha256" ]] || return 1

  handy_path="$(command -v handy 2>/dev/null)" || return 1
  owning_nvra="$(dictation_owning_nvra "$handy_path")" || return 1
  [[ "$owning_nvra" == "$(dictation_pinned_nvra)" ]] || return 1

  for package in "${packages[@]}"; do
    rpm -q "$package" >/dev/null 2>&1 || return 1
  done
}

if [[ "$dry_run" == "true" ]]; then
  if pin_is_recorded; then
    pin_plan="$handy_rpm_sha256"
  else
    pin_plan="not recorded — the install will stop before downloading anything"
  fi

  cat <<EOF

Fedora dictation installation plan
------------------------------------

Application:        Handy $handy_version (local, offline speech-to-text)
Provider:           pinned upstream release rpm, verified by SHA-256
Artifact:           $handy_rpm
Source:             $handy_url
Pinned SHA-256:     $pin_plan
Signature:          upstream signs with Tauri/minisign, not an RPM GPG key, so
                    there is no RPM signature to check and the pinned digest
                    is what is verified instead; no signature checking is
                    relaxed anywhere to install it
Fedora packages:    ${packages[*]}
Text insertion:     wtype (Wayland virtual keyboard); no /dev/uinput, no
                    'input' group, no dotool
Dictation key:      Super+O, owned by Sway (pkill -USR2 -x handy)
Transcription:      local only; no account, API key or cloud endpoint is
                    configured by this profile
Models:             downloaded by Handy on first use into
                    ~/.config/com.pais.handy/models, never into this repository

Steps:
  1. Install the Fedora-owned Wayland dependencies: ${packages[*]}.
  2. Download $handy_rpm and verify it against the pinned SHA-256.
  3. Install the digest-verified local rpm with dnf.
  4. Record the profile in \$XDG_CONFIG_HOME/dotfiles/dictation.conf.

No changes were made.

EOF
  exit 0
fi

require_fedora

# Before the network, before sudo, before anything: an artifact nothing can
# check is an artifact this profile will not install.
pin_is_recorded || die "$(
  cat <<EOF
No SHA-256 is pinned for $handy_rpm, so its integrity cannot be checked and
the dictation profile will not install it. Download that exact artifact from
$handy_url, take its SHA-256, and record the digest in
platforms/fedora/lib/dictation.sh. The two commands are in
docs/profiles/dictation.md, "Bumping the pinned Handy release".
EOF
)"

if installed_matches_pin; then
  info "Handy $handy_version is already installed from the pinned artifact"
else
  info "Installing the Wayland dependencies Handy needs: ${packages[*]}"
  sudo dnf install -y "${packages[@]}"

  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "$work_dir"' EXIT
  rpm_path="$work_dir/$handy_rpm"

  info "Downloading Handy $handy_version"
  # network-source: handy-release
  fetch_to_file "$handy_url" "$rpm_path" "the Handy $handy_version rpm"
  fetch_verify_sha256 "$rpm_path" "$handy_rpm_sha256" \
    "the Handy $handy_version rpm"

  # Plain dnf, with no flag and no --setopt that relaxes signature checking.
  # Fedora does not GPG-check a local package file by default, and whether it
  # does is the machine's own dnf policy to state, not this installer's to
  # override: a machine that has deliberately turned local signature checking
  # on will refuse this unsigned artifact, and refusing is the correct answer
  # there. The bytes have already been held to the pinned digest above.
  info "Installing the verified Handy rpm"
  sudo dnf install -y "$rpm_path"

  rm -rf -- "$work_dir"
  trap - EXIT
fi

ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=dictation\n'
  printf 'application=handy\n'
  printf 'provider=%s\n' "$DICTATION_HANDY_PROVIDER"
  printf 'version=%s\n' "$handy_version"
  printf 'rpm=%s\n' "$handy_rpm"
  printf 'sha256=%s\n' "$handy_rpm_sha256"
  printf 'paste_backend=wtype\n'
  printf 'toggle=sway-sigusr2\n'
} | profile_state_write_content "$state_file" dictation

success "Dictation profile installed (Handy $handy_version)"

cat <<'EOF'

Handy is installed but has no speech model yet. Open it once to pick one; it
downloads into ~/.config/com.pais.handy/ and never into this repository.

Press Super+O to start and stop dictation. Sway owns that key and signals the
running Handy process, so Handy must be running for it to do anything — start
it from Fuzzel, or add `exec handy --start-hidden` to ~/.config/sway/local.conf
if you want it every session. See docs/profiles/dictation.md.

EOF
