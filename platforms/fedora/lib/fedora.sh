#!/usr/bin/env bash

# Fedora-specific helpers. Source common/lib/common.sh before this file.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/fetch.sh"
# shellcheck source=../../../common/lib/capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/capabilities.sh"

FEDORA_STOW_DIR="$DOTFILES_ROOT/platforms/fedora/stow"

# fedora_retired_stow_links <package>: links in HOME an earlier layout of this
# checkout left where <package> now links, one per line. Sway and Waybar were
# top-level packages before they moved under platforms/fedora/stow, and the
# wallpapers theme-assets owns used to belong to the Sway package. That
# package has since moved the other way, to the top of the checkout, because
# the images are shared rather than Fedora's; the retired links it replaces
# are the same ones either way. This is the
# one place they are named: the Stow script removes them before stowing the
# package, and both its preflight and the installer's pass them as --replaces
# exemptions, so neither refuses the machines the migration exists for.
fedora_retired_stow_links() {
  local package="$1"
  local retired_prefix
  local source_path
  local relative_path
  local target_path

  local package_dir

  case "$package" in
  sway | waybar) retired_prefix="$DOTFILES_ROOT/$package/" ;;
  theme-assets) retired_prefix="$FEDORA_STOW_DIR/sway/.local/share/wallpapers/" ;;
  *) return 0 ;;
  esac
  # Resolved, not assumed: theme-assets is shared and lives at the top of the
  # checkout, so the migration reads its files from there while still
  # comparing them against the Sway package that used to own them.
  package_dir="$(capability_stow_package_root fedora "$package")/$package"
  [[ -d "$package_dir" ]] || return 0

  while IFS= read -r -d '' source_path; do
    relative_path="${source_path#"$package_dir/"}"
    target_path="$HOME/$relative_path"

    [[ -L "$target_path" ]] || continue
    [[ "$(realpath -m "$target_path")" != "$retired_prefix"* ]] ||
      printf '%s\n' "$target_path"
  done < <(find "$package_dir" \( -type f -o -type l \) -print0)
}

# fedora_retired_link_exemptions <package>...: the --replaces argument vector
# preflight_stow_packages takes for those packages, empty when none apply.
fedora_retired_link_exemptions() {
  local package retired_link
  for package in "$@"; do
    while IFS= read -r retired_link; do
      printf -- '--replaces\n%s\n' "$retired_link"
    done < <(fedora_retired_stow_links "$package")
  done
}

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
# The host is stated once; the key and repository URLs are paths on it.
TERRA_HOST_URL="${TERRA_HOST_URL:-https://repos.fyralabs.com}"
TERRA_KEY_URL_TEMPLATE="${TERRA_KEY_URL_TEMPLATE:-$TERRA_HOST_URL/terra%s/key.asc}"
TERRA_REPO_URL_TEMPLATE="${TERRA_REPO_URL_TEMPLATE:-$TERRA_HOST_URL/terra%s}"

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

# terra_key_fingerprints <path>: the primary fingerprint of every key in an
# ASCII-armoured key file, one per line, upper case.
#
# Reading only the first one is not a shortcut, it is the whole trust hole: a
# key file carries as many keys as whoever served it chose to put in it, and
# `rpm --import` trusts all of them. A pin checked against the first block
# establishes nothing about the second. This is the same pub/fpr pairing
# rpm_keyring_fingerprints below does, for the same reason.
terra_key_fingerprints() {
  gpg --show-keys --with-colons -- "$1" 2>/dev/null |
    awk -F: '
      $1 == "pub" { primary = 1; next }
      $1 == "fpr" && primary { print toupper($10); primary = 0 }
    '
}

# terra_release_installed: true when this machine already has the Terra
# repository, which is what decides whether a run has to fetch anything from
# Terra at all. Read by the bootstrap below and by the installer's preflight.
terra_release_installed() {
  rpm -q terra-release >/dev/null 2>&1
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
  local -a observed_keys=()

  if terra_release_installed; then
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

  # Every key in the file, because the import below trusts every key in the
  # file. One primary key is what a Terra release key.asc holds and what both
  # branches below are able to reason about: a second key is either a change
  # upstream made and this repository has not reviewed, or a substitution, and
  # neither is something to decide from the first block alone.
  mapfile -t observed_keys < <(terra_key_fingerprints "$staged")
  ((${#observed_keys[@]} > 0)) ||
    die "Downloaded Terra key is not a usable OpenPGP public key: $key_url"
  ((${#observed_keys[@]} == 1)) ||
    die "The Terra $releasever key file carries ${#observed_keys[@]} keys and importing it would trust all of them: ${observed_keys[*]}. Expected exactly one. Review $key_url before continuing."
  observed="${observed_keys[0]}"

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
  # network-source: terra-signing-key
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

  terra_release_installed ||
    die "The Terra bootstrap did not install terra-release."
}

# repo_gpgcheck_values <repo_id>: the effective signature-checking settings DNF
# applies to a repository, as "<option> = <value>" lines, or nothing when DNF
# does not know the repository. DNF resolves the repository files and every
# override itself, so this reads what DNF will actually enforce rather than one
# file's spelling of it. Read-only and sudo-free.
repo_gpgcheck_values() {
  dnf --dump-repo-config="$1" 2>/dev/null |
    awk -F ' = ' '$1 == "gpgcheck" || $1 == "pkg_gpgcheck" { print $1 " = " $2 }'
}

# verify_repo_trust_root <repo_id> <human name>: asserts that DNF still
# enforces package signatures for a repository this installer added.
#
# Every repository the installer adds is added once and then never looked at
# again -- the bootstraps all return early on a machine that already has
# theirs -- so a repository file later edited to gpgcheck=0, or shipped that
# way, is only ever caught by a verifier. Source common/lib/verify.sh first.
verify_repo_trust_root() {
  local repo_id="$1" human_name="$2" gpgcheck_values setting unchecked=""

  gpgcheck_values="$(repo_gpgcheck_values "$repo_id")"
  if ! grep -q '^gpgcheck = ' <<<"$gpgcheck_values"; then
    fail "DNF reports no gpgcheck setting for the $repo_id repository;" \
      "$human_name packages may install without signature verification"
    return 0
  fi

  while IFS= read -r setting; do
    [[ "$setting" == *' = 1' ]] || unchecked+="${unchecked:+, }$setting"
  done <<<"$gpgcheck_values"
  if [[ -n "$unchecked" ]]; then
    fail "$repo_id repository has $unchecked, expected 1;" \
      "$human_name packages install without signature verification"
  else
    pass "$repo_id repository enforces package signatures (gpgcheck = 1)"
  fi
}

# rpm_keyring_fingerprints: the primary fingerprint of every key in the RPM
# keyring, one per line, upper case. RPM 4 names an imported key by its short
# key ID and RPM 6 by its fingerprint, so the fingerprint is read from the
# armoured key each keyring entry carries instead of from its package name.
rpm_keyring_fingerprints() {
  rpm -q gpg-pubkey --qf '%{DESCRIPTION}\n' 2>/dev/null |
    gpg --show-keys --with-colons 2>/dev/null |
    awk -F: '
      $1 == "pub" { primary = 1; next }
      $1 == "fpr" && primary { print toupper($10); primary = 0 }
    '
}

# verify_terra_trust_root: re-asserts, on an installed machine, the trust root
# ensure_terra_repository established once. The bootstrap returns early for
# good once terra-release is installed, so a repository later edited to
# gpgcheck=0 or a signing key removed from the keyring is only ever caught
# here. Read-only and sudo-free. Source common/lib/verify.sh first.
verify_terra_trust_root() {
  local releasever pinned

  if ! rpm -q terra-release >/dev/null 2>&1; then
    fail "terra-release is not installed; run" \
      "./platforms/fedora/scripts/install-terra.sh"
    return 0
  fi

  verify_repo_trust_root terra Terra

  releasever="$(rpm -E %fedora 2>/dev/null || true)"
  if [[ ! "$releasever" =~ ^[0-9]+$ ]]; then
    fail "Could not determine the Fedora release version to check the Terra signing key"
    return 0
  fi
  if [[ ! -r "$TERRA_KEY_MANIFEST" ]]; then
    fail "Terra key manifest is not readable: $TERRA_KEY_MANIFEST"
    return 0
  fi

  pinned="$(terra_pinned_fingerprint "$releasever")"
  if [[ -z "$pinned" ]]; then
    warning "No pinned Terra signing key for Fedora $releasever in" \
      "$TERRA_KEY_MANIFEST; the RPM keyring cannot be checked against a" \
      "reviewed fingerprint"
  elif rpm_keyring_fingerprints | grep -Fxq -- "$pinned"; then
    pass "Terra signing key for Fedora $releasever is in the RPM keyring" \
      "and matches the pinned fingerprint $pinned"
  else
    fail "The pinned Terra signing key for Fedora $releasever ($pinned)" \
      "is not in the RPM keyring"
  fi
}

# The directory distribution-gpg-keys installs the RPM Fusion signing keys
# into, and the directory DNF reads repository files from. Both are
# overridable so the suite can build a real layout without writing to /etc or
# installing a package.
RPM_FUSION_KEY_DIR="${RPM_FUSION_KEY_DIR:-/usr/share/distribution-gpg-keys/rpmfusion}"
DNF_REPO_DIR="${DNF_REPO_DIR:-/etc/yum.repos.d}"

# rpm_fusion_key_path <variant> <releasever>: where the reviewed signing key
# for free or nonfree lives once distribution-gpg-keys is installed.
rpm_fusion_key_path() {
  printf '%s/RPM-GPG-KEY-rpmfusion-%s-fedora-%s\n' "$RPM_FUSION_KEY_DIR" "$1" "$2"
}

ensure_rpm_fusion_repositories() {
  if rpm -q \
    rpmfusion-free-release \
    rpmfusion-nonfree-release >/dev/null 2>&1; then
    info "RPM Fusion repositories already installed"
    return
  fi

  local fedora_version variant key
  fedora_version="$(rpm -E %fedora)"
  [[ "$fedora_version" =~ ^[0-9]+$ ]] ||
    die "Could not determine the Fedora release version for the RPM Fusion bootstrap."

  # The two release RPMs are what install the keys every later RPM Fusion
  # package is checked against, so until they are installed there is nothing
  # on the machine to check *them* against: Fedora ships no RPM Fusion signing
  # keys in its own keyring and dnf's localpkg_gpgcheck is off by default.
  # HTTPS to mirrors.rpmfusion.org used to be the entire trust boundary, which
  # means one successful interception over the install window left a
  # permanent, self-consistent trust root behind.
  #
  # Fedora does ship distribution-gpg-keys, its own signed package carrying
  # the RPM Fusion keys, so the keys arrive through a package DNF has already
  # verified against Fedora's keyring, and the release RPMs are then checked
  # by signature like any other package.
  # network-source: distribution-gpg-keys
  if ! rpm -q distribution-gpg-keys >/dev/null 2>&1; then
    info "Installing distribution-gpg-keys for the RPM Fusion signing keys"
    sudo dnf install -y distribution-gpg-keys ||
      die "Could not install distribution-gpg-keys, which carries the RPM Fusion signing keys."
  fi

  for variant in free nonfree; do
    key="$(rpm_fusion_key_path "$variant" "$fedora_version")"
    # No fallback to an unverified install: a missing key means this Fedora
    # release is newer than the keys distribution-gpg-keys carries, and the
    # honest answer is to say so rather than to install the release RPMs the
    # way this repository has just stopped installing them.
    [[ -r "$key" ]] ||
      die "No reviewed RPM Fusion $variant signing key for Fedora $fedora_version at $key. Update distribution-gpg-keys, or install the RPM Fusion repositories by hand once you have verified the release packages."
    info "Importing the RPM Fusion $variant signing key for Fedora $fedora_version"
    # network-source: distribution-gpg-keys
    sudo rpm --import "$key" ||
      die "Could not import the RPM Fusion $variant signing key."
  done

  info "Enabling the RPM Fusion repositories"
  # network-source: rpmfusion-free-release,rpmfusion-nonfree-release
  sudo dnf install -y \
    --setopt=localpkg_gpgcheck=1 \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"
}

# rpm_fusion_repo_ids <variant>: every repository id the release package owns,
# read from the .repo files it installed. Each variant ships more than one
# repository -- the base one, updates, and the testing ones -- and gpgcheck=0
# in any of them is the same hole, so the set is taken from the package's own
# file list rather than from names written out here.
rpm_fusion_repo_ids() {
  local path
  rpm -ql "rpmfusion-$1-release" 2>/dev/null | while IFS= read -r path; do
    [[ "$path" == "$DNF_REPO_DIR"/*.repo && -r "$path" ]] || continue
    sed -n 's/^\[\([^]]*\)\]$/\1/p' "$path"
  done
}

# verify_rpm_fusion_trust_root: re-asserts that DNF still enforces signatures
# for the RPM Fusion repositories. The two release packages are what install
# the keys every later RPM Fusion package is checked against, so a repository
# of theirs left at gpgcheck=0 is the one that matters most and the one
# nothing looked at. Read-only and sudo-free. Source common/lib/verify.sh
# first.
verify_rpm_fusion_trust_root() {
  local variant repo_ids repo_id installed=""

  for variant in free nonfree; do
    rpm -q "rpmfusion-$variant-release" >/dev/null 2>&1 &&
      installed+="${installed:+ }$variant"
  done

  # Optional, so absence is a state to report rather than a failure -- but it
  # is reported, because a section that prints nothing reads as a section that
  # found nothing wrong.
  if [[ -z "$installed" ]]; then
    pass "no RPM Fusion repositories on this machine, so none to enforce"
    return 0
  fi

  for variant in free nonfree; do
    if [[ " $installed " != *" $variant "* ]]; then
      fail "rpmfusion-$variant-release is not installed while its sibling is;" \
        "rerun the desktop-tools installer to restore both repositories"
      continue
    fi
    repo_ids="$(rpm_fusion_repo_ids "$variant")"
    if [[ -z "$repo_ids" ]]; then
      fail "rpmfusion-$variant-release owns no readable repository file, so" \
        "whether RPM Fusion $variant packages are signature-checked is unknown"
      continue
    fi
    while IFS= read -r repo_id; do
      [[ -n "$repo_id" ]] || continue
      verify_repo_trust_root "$repo_id" "RPM Fusion $variant"
    done <<<"$repo_ids"
  done
}
