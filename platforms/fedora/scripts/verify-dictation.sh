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

verify_reset

# Read-only throughout. Nothing here starts Handy, opens a microphone,
# downloads a model, or reads a transcription: the profile's whole point is
# that dictated text stays on the machine, and a verifier that touched any of
# it would be the one thing in this repository that did not honour that.

state_file="${DICTATION_STATE_FILE:-$XDG_CONFIG_HOME/dotfiles/dictation.conf}"
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

# One owner, and it must be the pinned rpm. An AppImage or a Flatpak installed
# beside it would shadow the rpm on PATH and update on a different schedule,
# which is exactly the duplicate ownership this profile exists to avoid.
if handy_path="$(command -v handy 2>/dev/null)"; then
  if owning_package="$(rpm -qf "$handy_path" 2>/dev/null)"; then
    pass "handy is rpm-owned: $owning_package"
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
  recorded_backend="$(profile_state_read "$state_file" paste_backend dictation 2>/dev/null || true)"

  pass "Handy $recorded_version, installed from a digest-verified rpm"
  if [[ "$recorded_sha" =~ ^[0-9a-f]{64}$ ]]; then
    pass "the installed artifact's pinned SHA-256 is recorded"
  else
    fail "the recorded state has no usable SHA-256 for the installed" \
      "artifact, so what is installed cannot be tied to a pinned release"
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
