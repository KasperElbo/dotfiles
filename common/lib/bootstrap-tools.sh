#!/usr/bin/env bash

# Pinned release archives for the two tools the Fedora WSL and Parrot CTF
# bootstraps install before any package manager of this repository exists:
# mise, and (on Fedora WSL) Starship.
#
# Both used to come from upstream's live install script (mise.run and
# starship.rs/install.sh), executed as it was served that minute: nothing
# authenticated the script before it ran, or the binary it then fetched (#504).
# Each upstream also publishes release archives with published checksums, so
# this file pins one release of each and the SHA-256 of every archive it may
# fetch. The archive is checked before anything is extracted, and no upstream
# code runs at install time at all: the binary is copied out and made
# executable, and that is the whole installation.
#
# Sourcing this file sets no shell options. Bumping a pin is a reviewed edit
# of the version and its digests together; take the digests from upstream's
# own checksum file for that release and confirm them against the downloaded
# archives. ./scripts/check-pin-freshness.sh reports when either pin is behind.
# See docs/supply-chain.md, "Bumping a bootstrap tool".

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi
# shellcheck source=fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/fetch.sh"

# mise: https://github.com/jdx/mise/releases, SHASUMS256.txt of the release.
BOOTSTRAP_MISE_VERSION="2026.9.12"
BOOTSTRAP_MISE_SHA256_X64="b4058dece685259910d3aba5782445996eea79dbdb3cf952a6eb81aadf0373ff"
BOOTSTRAP_MISE_SHA256_ARM64="e4a0921da0a76ce4666832d5b57b6f0eb9f22d149ba92845ebae4c38638c6775"

# Starship: https://github.com/starship/starship/releases, the .sha256 file
# published beside each archive.
BOOTSTRAP_STARSHIP_VERSION="1.26.0"
BOOTSTRAP_STARSHIP_SHA256_X86_64="b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3"
BOOTSTRAP_STARSHIP_SHA256_AARCH64="dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"

# bootstrap_tool_artifact <mise|starship>: the release asset this machine
# runs, its pinned digest, and the path of the binary inside the archive, as
# three tab-separated fields. An architecture with no pinned digest is a
# refusal naming it, never a guess.
bootstrap_tool_artifact() {
  local tool="$1" machine
  machine="$(uname -m)"

  case "$tool/$machine" in
  mise/x86_64)
    printf '%s\t%s\t%s\n' "mise-v${BOOTSTRAP_MISE_VERSION}-linux-x64.tar.gz" \
      "$BOOTSTRAP_MISE_SHA256_X64" mise/bin/mise
    ;;
  mise/aarch64 | mise/arm64)
    printf '%s\t%s\t%s\n' "mise-v${BOOTSTRAP_MISE_VERSION}-linux-arm64.tar.gz" \
      "$BOOTSTRAP_MISE_SHA256_ARM64" mise/bin/mise
    ;;
  starship/x86_64)
    printf '%s\t%s\t%s\n' starship-x86_64-unknown-linux-musl.tar.gz \
      "$BOOTSTRAP_STARSHIP_SHA256_X86_64" starship
    ;;
  starship/aarch64 | starship/arm64)
    printf '%s\t%s\t%s\n' starship-aarch64-unknown-linux-musl.tar.gz \
      "$BOOTSTRAP_STARSHIP_SHA256_AARCH64" starship
    ;;
  *)
    die "No pinned $tool release for $machine; add its digest to common/lib/bootstrap-tools.sh."
    ;;
  esac
}

# bootstrap_tool_url <mise|starship> <artifact>
#
# DOTFILES_TEST_BOOTSTRAP_ARCHIVES is the suite's seam, the same shape as
# DOTFILES_TEST_HANDY_RPM: when set, it names a directory holding the
# archives the suite treats as pinned, and the URL is on the reserved .invalid
# domain, which resolves nowhere, so only a stubbed download can answer it.
bootstrap_tool_url() {
  local tool="$1" artifact="$2"

  if [[ -n "${DOTFILES_TEST_BOOTSTRAP_ARCHIVES:-}" ]]; then
    printf 'https://dotfiles-test.invalid/%s/%s\n' "$tool" "$artifact"
    return 0
  fi
  case "$tool" in
  mise)
    # network-source: mise-release
    printf 'https://github.com/jdx/mise/releases/download/v%s/%s\n' \
      "$BOOTSTRAP_MISE_VERSION" "$artifact"
    ;;
  starship)
    # network-source: starship-release
    printf 'https://github.com/starship/starship/releases/download/v%s/%s\n' \
      "$BOOTSTRAP_STARSHIP_VERSION" "$artifact"
    ;;
  *) die "Unknown bootstrap tool: $tool" ;;
  esac
}

# bootstrap_tool_digest <artifact> <pinned-digest>: the digest the download
# must match. Under the suite's seam, that of the same-named archive in the
# seam directory, so a stub serving anything else is a mismatch exactly as a
# tampered upstream archive would be.
bootstrap_tool_digest() {
  local artifact="$1" pinned="$2"

  if [[ -n "${DOTFILES_TEST_BOOTSTRAP_ARCHIVES:-}" ]]; then
    fetch_sha256 "$DOTFILES_TEST_BOOTSTRAP_ARCHIVES/$artifact"
    return
  fi
  printf '%s\n' "$pinned"
}

# install_bootstrap_tool <mise|starship> <destination>
#
# Downloads the pinned archive into a private directory, refuses it unless its
# SHA-256 equals the pin, and only then extracts the one binary and installs it
# at <destination>, mode 0755. Nothing from the archive is executed here.
install_bootstrap_tool() {
  local tool="$1" destination="$2"
  local artifact pinned member url digest work_dir

  IFS=$'\t' read -r artifact pinned member < <(bootstrap_tool_artifact "$tool")
  [[ -n "$artifact" ]] || die "No pinned $tool release for this machine."
  url="$(bootstrap_tool_url "$tool" "$artifact")"
  digest="$(bootstrap_tool_digest "$artifact" "$pinned")" ||
    die "Could not read the pinned digest for $artifact"

  work_dir="$(mktemp -d)" || die "Could not create a staging directory for $tool"
  chmod 700 -- "$work_dir"
  # Every step carries its own guard. The subshell is the condition of an
  # `if !`, where Bash suppresses errexit and a `set -e` inside does not bring
  # it back, so a step without one is carried past and only the last command's
  # status is reported: a tar that extracted the binary and then failed ended
  # in a successful install (#539). scripts/validate-errexit-conditions.py
  # refuses the `set -e` that used to stand here claiming otherwise.
  if ! (
    fetch_to_file "$url" "$work_dir/$artifact" "the pinned $tool release"
    fetch_verify_sha256 "$work_dir/$artifact" "$digest" "the pinned $tool release"
    tar -xzf "$work_dir/$artifact" -C "$work_dir" -- "$member" ||
      die "Could not extract $member from $artifact"
    [[ -f "$work_dir/$member" && ! -L "$work_dir/$member" ]] ||
      die "The pinned $tool release has no regular file at $member"
    ensure_dir "$(dirname -- "$destination")" ||
      die "Could not create the directory for $destination"
    install -m 0755 -- "$work_dir/$member" "$destination" ||
      die "Could not install $tool at $destination"
  ); then
    rm -rf -- "$work_dir"
    die "The pinned $tool release was not installed; nothing from it was executed."
  fi
  rm -rf -- "$work_dir"
}
