#!/usr/bin/env bash

# Fedora-specific helpers. Source common/lib/common.sh before this file.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/fetch.sh"

require_fedora() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id

  command_exists dnf || die "This installer requires Fedora and DNF."
  command_exists rpm || die "This installer requires Fedora and RPM."
  [[ -r "$os_release_file" ]] || die "Cannot read $os_release_file"

  os_id="$(
    awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' \
      "$os_release_file"
  )"

  [[ "$os_id" == "fedora" ]] || die "This installer supports Fedora only."
}

TERRA_KEY_MANIFEST="${TERRA_KEY_MANIFEST:-$DOTFILES_ROOT/config/terra-keys.tsv}"
TERRA_KEY_URL_TEMPLATE="${TERRA_KEY_URL_TEMPLATE:-https://repos.fyralabs.com/terra%s/key.asc}"
TERRA_REPO_URL_TEMPLATE="${TERRA_REPO_URL_TEMPLATE:-https://repos.fyralabs.com/terra%s}"

# terra_pinned_fingerprint <releasever>: the signing-key fingerprint this
# repository has reviewed for that Fedora release, or empty when the release
# predates or postdates the pinned set.
terra_pinned_fingerprint() {
  local releasever="$1"

  [[ -r "$TERRA_KEY_MANIFEST" ]] ||
    die "Terra key manifest is not readable: $TERRA_KEY_MANIFEST"

  awk -F '\t' -v want="$releasever" \
    '$1 !~ /^#/ && $1 == want { print toupper($2); found = 1; exit } END { exit !found }' \
    "$TERRA_KEY_MANIFEST" 2>/dev/null || true
}

# terra_key_fingerprint <path>: primary fingerprint of an ASCII-armoured key.
terra_key_fingerprint() {
  gpg --show-keys --with-colons -- "$1" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }'
}

# Terra's own documentation bootstraps with --nogpgcheck because the signing
# key ships inside terra-release itself. This repository does not accept that
# trust hole: Terra also publishes the key at a stable HTTPS URL, so the key is
# fetched first, checked against a fingerprint pinned in config/terra-keys.tsv,
# imported, and only then is terra-release installed with GPG checking on.
#
# An unpinned Fedora release is the one remaining trust boundary. It is never
# silently accepted: the fingerprint is printed and must be acknowledged with
# TERRA_TRUST_KEY_FINGERPRINT, or confirmed interactively.
ensure_terra_repository() {
  local releasever key_url repo_url staged pinned observed work_dir

  if rpm -q terra-release >/dev/null 2>&1; then
    info "Terra repository already installed"
    return
  fi

  require_command gpg
  require_command curl

  releasever="$(rpm -E %fedora)"
  [[ "$releasever" =~ ^[0-9]+$ ]] ||
    die "Could not determine the Fedora release version for the Terra bootstrap."

  # shellcheck disable=SC2059 # The template is a repository-controlled format.
  key_url="$(printf "$TERRA_KEY_URL_TEMPLATE" "$releasever")"
  # shellcheck disable=SC2059
  repo_url="$(printf "$TERRA_REPO_URL_TEMPLATE" "$releasever")"

  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "$work_dir"' RETURN
  staged="$work_dir/terra-key.asc"

  info "Fetching the Terra $releasever signing key"
  # network-source: terra-signing-key
  fetch_to_file "$key_url" "$staged" "the Terra $releasever signing key"

  observed="$(terra_key_fingerprint "$staged")"
  [[ -n "$observed" ]] ||
    die "Downloaded Terra key is not a usable OpenPGP public key: $key_url"

  pinned="$(terra_pinned_fingerprint "$releasever")"
  if [[ -n "$pinned" ]]; then
    [[ "$observed" == "$pinned" ]] ||
      die "Terra $releasever signing key fingerprint mismatch: expected $pinned, got $observed"
    info "Terra $releasever signing key matches the pinned fingerprint $observed"
  else
    warn "No pinned Terra signing key for Fedora $releasever in $TERRA_KEY_MANIFEST."
    warn "Downloaded key fingerprint: $observed"
    if [[ -n "${TERRA_TRUST_KEY_FINGERPRINT:-}" ]]; then
      [[ "${TERRA_TRUST_KEY_FINGERPRINT^^}" == "$observed" ]] ||
        die "TERRA_TRUST_KEY_FINGERPRINT does not match the downloaded key: $observed"
      warn "Accepting the Terra key on the caller's explicit acknowledgement."
    elif [[ -t 0 ]] && confirm "Trust Terra signing key $observed for Fedora $releasever?"; then
      warn "Accepting the Terra key on interactive confirmation."
    else
      die "Refusing to import an unpinned Terra signing key. Verify $observed against https://docs.terrapkg.com, then add it to $TERRA_KEY_MANIFEST or rerun with TERRA_TRUST_KEY_FINGERPRINT=$observed"
    fi
  fi

  info "Importing the Terra $releasever signing key"
  sudo rpm --import "$staged" ||
    die "Could not import the Terra signing key."

  info "Enabling the Terra repository"
  # No --nogpgcheck: the key above is already in the RPM keyring, so the
  # release package is signature-checked like any other Terra package.
  # network-source: terra-repo
  sudo dnf install -y \
    --setopt=terra.gpgcheck=1 \
    --repofrompath "terra,$repo_url" \
    terra-release

  rpm -q terra-release >/dev/null 2>&1 ||
    die "The Terra bootstrap did not install terra-release."
}

ensure_rpm_fusion_repositories() {
  if rpm -q \
    rpmfusion-free-release \
    rpmfusion-nonfree-release >/dev/null 2>&1; then
    info "RPM Fusion repositories already installed"
    return
  fi

  local fedora_version
  fedora_version="$(rpm -E %fedora)"

  info "Enabling the RPM Fusion repositories"
  # The release RPMs are signed by the Fedora-shipped RPM Fusion keys, which
  # dnf already trusts; the HTTPS transport is the only pre-trust boundary.
  # network-source: rpmfusion-free-release,rpmfusion-nonfree-release
  sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"
}
