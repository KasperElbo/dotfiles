#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/capabilities.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/dictation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dictation.sh"

verify_reset

# Read-only throughout. Nothing here starts Handy, opens a microphone,
# downloads a model, or reads a transcription: the profile's whole point is
# that dictated text stays on the machine, and a verifier that touched any of
# it would be the one thing in this repository that did not honour that.

state_file="${DICTATION_STATE_FILE:-$(dictation_state_file)}"
sway_config="${DICTATION_SWAY_CONFIG:-$XDG_CONFIG_HOME/sway/config}"

section "Dictation commands"

# handy is the application; wtype is how it puts the transcription into the
# focused window on Wayland. Without wtype Handy silently falls back to a path
# that does not work on wlroots, so a missing wtype is a failure, not a note.
check_command handy
check_command wtype

section "Fedora-owned Wayland dependencies"

# The package list is read from config/capabilities.tsv rather than repeated
# here, so the installer and the verifier cannot disagree about what the
# profile owns.
if ! declared_packages="$(capability_packages fedora dictation)"; then
  fail "Could not read the dictation packages from the capability manifest"
  declared_packages=""
fi

if [[ -n "$declared_packages" ]]; then
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if rpm -q "$package" >/dev/null 2>&1; then
      pass "$package is installed"
    else
      fail "$package is not installed"
    fi
  done <<<"$declared_packages"
fi

section "Handy package ownership"

# What the repository says should be installed. It is read from
# platforms/fedora/lib/dictation.sh, the same file the installer reads, so the
# two cannot drift: a bump changes one file and both sides follow it.
pinned_version="$(dictation_pinned_version)"
pinned_sha256="$(dictation_pinned_sha256)"
pinned_rpm="$(dictation_pinned_rpm)"
pinned_nvra="$(dictation_pinned_nvra)"

# A verifier that cannot read its own expectation has nothing to check against,
# and must say so rather than passing the checks it can still reach.
if [[ ! "$pinned_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  fail "This repository states no usable pinned SHA-256 for Handy, so nothing" \
      "below can establish that what is installed is what it pins; see" \
      "docs/profiles/dictation.md, 'Bumping the pinned Handy release'"
fi

# One owner, and it must be the pinned rpm. An AppImage or a Flatpak installed
# beside it would shadow the rpm on PATH and update on a different schedule,
# which is exactly the duplicate ownership this profile exists to avoid.
#
# Identity, not merely ownership. `rpm -qf` answering at all says only that
# some package claims the file; this compares its name-version-release.arch
# against the pinned artifact's, which is the one fact that ties the binary on
# PATH to the release this repository chose and digest-verified. Checking only
# that *an* rpm owned it accepted a machine running an unrelated build.
#
# Nothing here runs handy. Its version is read from the package database, not
# from the application, because starting a dictation application to interview
# it is exactly the thing this profile promises not to do.
if handy_path="$(command -v handy 2>/dev/null)"; then
  if owning_nvra="$(dictation_owning_nvra "$handy_path")"; then
    if [[ "$owning_nvra" == "$pinned_nvra" ]]; then
      pass "handy is the pinned rpm: $owning_nvra"
    else
      fail "handy at $handy_path belongs to $owning_nvra, not the pinned" \
        "$pinned_nvra; this machine is running a different build from the one" \
        "this repository pins and digest-verified, so rerun" \
        "./install.sh --dictation"
    fi

    # An rpm whose installed files no longer match what it shipped is an
    # altered package: the digest checked at download time says nothing about
    # bytes replaced afterwards. rpm's own database holds the per-file digests,
    # so this asks it rather than recomputing anything, and it neither starts
    # the application nor reads a model or a transcription.
    #
    # A configuration file the operator edited is not tampering, so the `c`
    # attribute is excluded; every other discrepancy is reported.
    if rpm_verify_output="$(rpm -V "$owning_nvra" 2>/dev/null)"; then
      pass "every file $owning_nvra installed still matches what it shipped"
    elif [[ -z "$rpm_verify_output" ]]; then
      # Discrepancies are printed; a non-zero status with nothing to show means
      # rpm could not answer, which is not the same as an intact package and
      # must not be reported as one.
      fail "rpm could not verify the files $owning_nvra installed, so nothing" \
        "here shows that the package on disk is still the one that was" \
        "installed"
    else
      altered="$(awk '$2 != "c" { print }' <<<"$rpm_verify_output")"
      if [[ -n "$altered" ]]; then
        fail "files installed by $owning_nvra no longer match what the" \
          "package shipped, so the verified artifact is not what is on disk" \
          "now: ${altered//$'\n'/; }"
      else
        pass "every file $owning_nvra installed still matches what it shipped"
      fi
    fi
  else
    fail "handy at $handy_path is owned by no rpm; this profile installs" \
      "Handy from a pinned release rpm, so an unowned binary is a second," \
      "unmanaged copy"
  fi
fi

if command_exists flatpak; then
  if flatpak info com.pais.handy >/dev/null 2>&1; then
    fail "Handy is also installed as a Flatpak (com.pais.handy); remove it" \
      "with 'flatpak uninstall com.pais.handy' so the pinned rpm is the" \
      "only owner"
  else
    pass "no duplicate Flatpak installation of Handy"
  fi
else
  pass "flatpak is not installed; no duplicate Flatpak ownership is possible"
fi

section "Recorded dictation profile"

if [[ ! -e "$state_file" ]]; then
  fail "No dictation profile state at $state_file; rerun" \
    "./install.sh --dictation"
elif ! profile_state_validate_file "$state_file" dictation >/dev/null 2>&1; then
  fail "The dictation profile state at $state_file is not readable as a" \
    "dictation profile"
else
  recorded_version="$(profile_state_read "$state_file" version dictation 2>/dev/null || true)"
  recorded_sha="$(profile_state_read "$state_file" sha256 dictation 2>/dev/null || true)"
  recorded_rpm="$(profile_state_read "$state_file" rpm dictation 2>/dev/null || true)"
  recorded_provider="$(profile_state_read "$state_file" provider dictation 2>/dev/null || true)"
  recorded_backend="$(profile_state_read "$state_file" paste_backend dictation 2>/dev/null || true)"

  # State is this profile's own record of what it did, so every value below is
  # checked against the repository's pin rather than accepted for being
  # well-formed. A syntactically valid digest of sixty-four zeroes used to pass
  # here and be reported as a digest-verified rpm.
  if [[ "$recorded_version" == "$pinned_version" ]]; then
    pass "Handy $recorded_version, the release this repository pins"
  else
    fail "the recorded state says Handy ${recorded_version:-no version}, but" \
      "this repository pins $pinned_version; the record is stale, so rerun" \
      "./install.sh --dictation"
  fi

  if [[ ! "$recorded_sha" =~ ^[0-9a-f]{64}$ ]]; then
    fail "the recorded state has no usable SHA-256 for the installed" \
      "artifact, so what is installed cannot be tied to a pinned release"
  elif [[ "$recorded_sha" == "$pinned_sha256" ]]; then
    pass "the installed artifact's digest is the pinned one"
  else
    fail "the recorded state was installed from an artifact whose SHA-256 is" \
      "$recorded_sha, but this repository pins $pinned_sha256; rerun" \
      "./install.sh --dictation"
  fi

  if [[ "$recorded_provider" == "$DICTATION_HANDY_PROVIDER" ]]; then
    pass "provider: $recorded_provider"
  else
    fail "the recorded state names provider" \
      "'${recorded_provider:-none}', not '$DICTATION_HANDY_PROVIDER'; this" \
      "profile owns the pinned-release-rpm route only"
  fi

  if [[ "$recorded_rpm" == "$pinned_rpm" ]]; then
    pass "artifact: $recorded_rpm"
  else
    fail "the recorded state names artifact '${recorded_rpm:-none}', not the" \
      "pinned $pinned_rpm; rerun ./install.sh --dictation"
  fi
  if [[ "$recorded_backend" == wtype ]]; then
    pass "text insertion backend: wtype (no /dev/uinput, no 'input' group)"
  else
    fail "unexpected text-insertion backend '$recorded_backend'; this" \
      "profile owns the wtype path only"
  fi
fi

section "Sway dictation binding"

# The compositor owns the key. Handy's own global shortcut cannot be
# registered on a wlroots compositor (no GlobalShortcuts portal), so the
# tracked Sway config is what makes dictation reachable at all.
if [[ -e "$sway_config" ]]; then
  if grep -Fq 'pkill -USR2 -x handy' "$sway_config"; then
    pass "Sway binds the dictation toggle (pkill -USR2 -x handy)"
  else
    fail "$sway_config has no dictation binding; the Sway session owns the" \
      "dictation key, so without it nothing can start a transcription"
  fi
else
  not_observed "No Sway configuration at $sway_config; the dictation binding" \
    "belongs to the optional Sway session and there is none to check here" \
    "(on KDE the shortcut is created by hand, see docs/profiles/dictation.md)"
fi

section "Privacy posture"

# Not a claim that no audio was ever recorded -- nothing can verify that --
# only that this repository is not where any of it could land.
if [[ "$DOTFILES_ROOT" == /* ]] && [[ -d "$DOTFILES_ROOT" ]]; then
  if [[ -e "$DOTFILES_ROOT/.config/com.pais.handy" ]] ||
    [[ -e "$DOTFILES_ROOT/com.pais.handy" ]]; then
    fail "Handy application state exists inside the checkout at" \
      "$DOTFILES_ROOT; models, history and settings belong in" \
      "$HOME/.config/com.pais.handy and must never be committed"
  else
    pass "no Handy models, history or settings inside the checkout"
  fi
fi

finish_verification "Dictation verification"
