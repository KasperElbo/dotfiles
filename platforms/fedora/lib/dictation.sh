#!/usr/bin/env bash

# The pinned Handy artifact, shared by the installer and the verifier.
#
# Sourcing this file intentionally sets no shell options and calls nothing: it
# is a set of constants plus small readers, so the script that installs the
# application and the verifier that proves it is installed can never disagree
# about which release, which digest, or which rpm is expected. Before this file
# existed the two did disagree, and silently: the installer verified a digest
# at download time and the verifier then accepted whatever version and
# syntactically valid digest the state file happened to record, so a machine
# running an unrelated build reported a digest-verified pinned rpm.
#
# Why a pinned release rpm rather than a package manager
# ------------------------------------------------------
# Handy is not packaged by Fedora, Terra or Flathub, so this profile owns one
# upstream release artifact: the .rpm published with a specific GitHub release,
# identified by the digest below. Upstream signs its releases with Tauri's
# minisign format rather than an RPM GPG signature, so there is no RPM
# signature for dnf to check, and nothing in this profile asks dnf to stop
# checking one. What stands in for the missing signature is this digest, which
# names one exact artifact rather than one publisher.
#
# Bumping the pin is therefore a reviewed act: edit the two values below
# together and nothing else. See docs/profiles/dictation.md, "Bumping the
# pinned Handy release", and the handy-release row in
# config/network-sources.tsv.

# The upstream release tag, without its leading "v".
DICTATION_HANDY_VERSION="0.9.7"

# SHA-256 of that release's .rpm, computed in this repository.
DICTATION_HANDY_SHA256="91efeac19e2af6e5d92b6adf27991eafb7f10ef4979558f486f61f6db1820053"

# The release's rpm release number and architecture, which the artifact's name
# and the identity rpm records both carry.
DICTATION_HANDY_RPM_RELEASE="1"
DICTATION_HANDY_RPM_ARCH="x86_64"

# Two names, and they are not the same name.
#
# The file upstream publishes is Handy-<version>-1.x86_64.rpm, with a capital
# H: the Tauri bundler takes it from the product name. The package name inside
# that file -- the %{NAME} rpm records, and therefore what `rpm -qf` answers
# with -- is `handy`, lower case. Both were read out of the header of the
# pinned artifact itself rather than assumed, because assuming that the leading
# field of the file name was the package name is wrong for exactly this package
# and would fail verification on a correctly installed machine.
#
# So a bump reads the package name back out of the artifact it downloads
# instead of copying the file name; docs/profiles/dictation.md, "Bumping the
# pinned Handy release", gives the one command that prints it.
DICTATION_HANDY_ARTIFACT_NAME="Handy"
DICTATION_HANDY_RPM_NAME="handy"

# Where this profile records what it installed.
DICTATION_STATE_RELATIVE_PATH="dotfiles/dictation.conf"

# The provider string the state file records. The verifier asserts it, so state
# written by some other mechanism cannot pass as this profile's work.
DICTATION_HANDY_PROVIDER="pinned-release-rpm"

# dictation_pinned_version: the release this profile installs.
dictation_pinned_version() {
  printf '%s\n' "$DICTATION_HANDY_VERSION"
}

# dictation_pinned_rpm: the exact artifact file name that release publishes.
dictation_pinned_rpm() {
  printf '%s-%s-%s.%s.rpm\n' \
    "$DICTATION_HANDY_ARTIFACT_NAME" "$DICTATION_HANDY_VERSION" \
    "$DICTATION_HANDY_RPM_RELEASE" "$DICTATION_HANDY_RPM_ARCH"
}

# dictation_pinned_nvra: the name-version-release.arch triple rpm reports for
# the installed package. This is what ties a binary on PATH to the pinned
# artifact: `rpm -qf` answers with this shape, so comparing the two establishes
# that the executable came from the package this profile installed and not from
# some other build that happens to be called handy.
#
# It is deliberately built from DICTATION_HANDY_RPM_NAME and not from the
# artifact file name above, which differs from it in case. Stripping `.rpm` off
# the file name would give Handy-<version>-1.x86_64 and match nothing.
dictation_pinned_nvra() {
  printf '%s-%s-%s.%s\n' \
    "$DICTATION_HANDY_RPM_NAME" "$DICTATION_HANDY_VERSION" \
    "$DICTATION_HANDY_RPM_RELEASE" "$DICTATION_HANDY_RPM_ARCH"
}

# dictation_pinned_sha256: the digest the downloaded artifact must have.
#
# Test seam. The suites cannot download a 112 MB release artifact, so they name
# a small fixture file instead and the digest checked is that file's own,
# computed here and never supplied by the caller. It lives in this shared
# reader rather than in the installer alone so that the installer and the
# verifier see one pin under test exactly as they do in production; a seam only
# one of them honoured would leave the other untested against real state.
#
# It cannot weaken the pinned download, because naming a fixture also replaces
# the URL: dictation_release_url below answers with a reserved .invalid host
# that resolves nowhere. The pinned URL is only ever paired with the pinned
# digest; no value of this variable makes the real artifact acceptable under a
# digest someone else chose. Set but empty leaves the pin unrecorded, which is
# how the installer's fail-closed guard is exercised.
dictation_pinned_sha256() {
  if [[ -n "${DOTFILES_TEST_HANDY_RPM+set}" ]]; then
    if [[ -n "$DOTFILES_TEST_HANDY_RPM" ]]; then
      sha256sum -- "$DOTFILES_TEST_HANDY_RPM" | cut -d' ' -f1
    else
      printf '\n'
    fi
    return 0
  fi
  printf '%s\n' "$DICTATION_HANDY_SHA256"
}

# dictation_pin_is_recorded: whether there is a digest to check the artifact
# against at all. An artifact nothing can check is one this profile will not
# install, so this is asked before the network and before sudo.
dictation_pin_is_recorded() {
  [[ "$(dictation_pinned_sha256)" =~ ^[0-9a-f]{64}$ ]]
}

# dictation_release_url: the exact release asset this profile installs. The URL
# is built from the pinned tag so the tag cannot drift from the download.
dictation_release_url() {
  local handy_version="$DICTATION_HANDY_VERSION"
  local handy_rpm
  handy_rpm="$(dictation_pinned_rpm)"

  if [[ -n "${DOTFILES_TEST_HANDY_RPM:-}" ]]; then
    # .invalid is reserved by RFC 2606 and resolves nowhere, so this URL can
    # never reach the real artifact; only a stubbed download answers it.
    printf 'https://dotfiles-test.invalid/%s\n' "$handy_rpm"
    return 0
  fi
  # network-source: handy-release
  printf 'https://github.com/cjpais/Handy/releases/download/v%s/%s\n' \
    "$handy_version" "$handy_rpm"
}

# dictation_state_file: the machine-local state file for this profile.
dictation_state_file() {
  printf '%s/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$DICTATION_STATE_RELATIVE_PATH"
}

# dictation_owning_nvra <path>: the name-version-release.arch of the rpm that
# owns a file, or a non-zero status when no rpm owns it. Read-only; it asks the
# local rpm database and runs nothing that was installed.
dictation_owning_nvra() {
  local path="$1" nvra

  nvra="$(rpm -qf --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$path" 2>/dev/null)" ||
    return 1
  [[ -n "$nvra" ]] || return 1
  printf '%s\n' "$nvra"
}
