#!/usr/bin/env bash

# A portable entry point, so it may be started under Apple's Bash 3.2: on macOS
# `env bash` resolves to /bin/bash whenever Homebrew is not ahead of it on PATH.
# Everything down to the modern-Bash guard therefore stays inside that dialect,
# and `set -euo pipefail` waits until after it, as scripts/lint.sh does.

# Scan this repository for committed credentials, with the same command
# locally and in CI.
#
# Why this exists
# ---------------
# README.md makes a categorical claim: nothing personal or secret is in this
# repository. Several profiles check their own credentials -- the SSH
# hardening drop-ins, the AI toolchain's key file -- but no check covered every
# tracked path, and none covered history at all. The claim was the one
# repository-wide promise with nothing behind it.
#
# Why a pinned binary rather than a GitHub Action
# -----------------------------------------------
# An action runs only inside a workflow, so a contributor could not run the
# gate before pushing and a fork could not run it at all. The scanner is
# therefore downloaded here from a version-pinned upstream release whose
# SHA-256 is recorded below, the same shape the dictation profile uses for the
# Handy rpm, and this one script is what both a workstation and
# .github/workflows/validate.yml run.
#
# What is scanned
# ---------------
# The working tree and the whole history reachable from HEAD, on every run.
# A commit range is available with --range for when that stops being cheap; at
# the size of this repository the full history scan is about a second, so
# scanning less would trade real coverage for nothing. See docs/testing.md,
# "Secret scanning".

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"

# shellcheck source=../common/lib/modern-bash.sh
. "$repo_root/common/lib/modern-bash.sh"
modern_bash_reexec ./scripts/scan-secrets.sh "$script_path" "$@" || exit 2

set -euo pipefail

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/fetch.sh
source "$repo_root/common/lib/fetch.sh"

# The pinned release. `scripts/check-pin-freshness.sh` reads `version` from
# this file through config/pin-freshness.tsv, so it stays a single quoted
# assignment; bumping the pin means editing the five lines below and nothing
# else. The digests are upstream's own, from gitleaks_<version>_checksums.txt
# in the same release; see docs/supply-chain.md, "Bumping the secret scanner".
version="8.30.1"
sha256_linux_x64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
sha256_linux_arm64="e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"
sha256_darwin_x64="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
sha256_darwin_arm64="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"

config_file="$repo_root/.gitleaks.toml"
range=""
scanned=""

usage() {
  cat <<'EOF'
Usage: ./scripts/scan-secrets.sh [options]

Scan this repository for committed credentials with a version-pinned gitleaks.
The working tree and the full history reachable from HEAD are both scanned.

Findings are redacted: the rule, the file and the line are reported, never the
matched secret, so a CI log never becomes the second place a credential lives.

Options:
  --range <A..B>  Scan only that commit range instead of the full history
  -h, --help      Show this help

Environment:
  DOTFILES_GITLEAKS  An existing gitleaks executable to use instead of
                     downloading the pinned release. The version is still
                     checked against the pin, so this cannot silently scan
                     with different rules.
EOF
}

while (($#)); do
  case "$1" in
  --range)
    [[ $# -ge 2 ]] || die "--range needs a commit range, such as main..HEAD"
    range="$2"
    shift 2
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

# platform_artifact: the release asset this machine runs, and its pinned
# digest. An unknown platform is a refusal rather than a guess: downloading
# the wrong architecture would fail the digest check anyway, and saying which
# platform is unsupported is more useful than a mismatch.
platform_artifact() {
  local kernel machine key digest
  kernel="$(uname -s)"
  machine="$(uname -m)"

  case "$kernel/$machine" in
  Linux/x86_64) key="linux_x64" digest="$sha256_linux_x64" ;;
  Linux/aarch64 | Linux/arm64) key="linux_arm64" digest="$sha256_linux_arm64" ;;
  Darwin/x86_64) key="darwin_x64" digest="$sha256_darwin_x64" ;;
  Darwin/arm64) key="darwin_arm64" digest="$sha256_darwin_arm64" ;;
  *)
    die "No pinned gitleaks build for $kernel/$machine. Add its digest from gitleaks_${version}_checksums.txt to scripts/scan-secrets.sh."
    ;;
  esac

  printf '%s\t%s\n' "gitleaks_${version}_${key}.tar.gz" "$digest"
}

# installed_version <executable>: the version it reports, or nothing.
installed_version() {
  "$1" version 2>/dev/null | tr -d '[:space:]'
}

# gitleaks_executable: the pinned scanner, downloading it once into the cache
# if it is not already there. Printed on stdout, so every other message in
# this function goes to stderr.
gitleaks_executable() {
  local artifact expected cache binary work_dir

  IFS=$'\t' read -r artifact expected < <(platform_artifact)

  if [[ -n "${DOTFILES_GITLEAKS:-}" ]]; then
    [[ -x "$DOTFILES_GITLEAKS" ]] ||
      die "DOTFILES_GITLEAKS is set to something that is not executable: $DOTFILES_GITLEAKS"
    local reported
    reported="$(installed_version "$DOTFILES_GITLEAKS")"
    [[ "$reported" == "$version" ]] ||
      die "DOTFILES_GITLEAKS reports version ${reported:-nothing}, but this repository pins $version. Scanning with different rules would make a pass mean something else."
    printf '%s\n' "$DOTFILES_GITLEAKS"
    return 0
  fi

  cache="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/gitleaks/$version"
  binary="$cache/gitleaks"

  if [[ -x "$binary" && "$(installed_version "$binary")" == "$version" ]]; then
    printf '%s\n' "$binary"
    return 0
  fi

  info "Downloading the pinned gitleaks $version" >&2
  work_dir="$(mktemp -d)"
  trap 'rm -rf -- "$work_dir"' EXIT

  # network-source: gitleaks-release
  fetch_to_file \
    "https://github.com/gitleaks/gitleaks/releases/download/v$version/$artifact" \
    "$work_dir/$artifact" "the pinned gitleaks $version"
  fetch_verify_sha256 "$work_dir/$artifact" "$expected" "the pinned gitleaks $version"

  tar -xzf "$work_dir/$artifact" -C "$work_dir" gitleaks
  ensure_dir "$cache"
  # Into place in one rename, so a second scan never finds a half-written
  # binary and a concurrent one never runs it.
  mv -f "$work_dir/gitleaks" "$binary"
  chmod 0755 "$binary"

  [[ "$(installed_version "$binary")" == "$version" ]] ||
    die "The downloaded gitleaks does not report $version; refusing to scan with it."

  rm -rf -- "$work_dir"
  trap - EXIT

  printf '%s\n' "$binary"
}

cd "$repo_root"

[[ -r "$config_file" ]] ||
  die "No scanner configuration at $config_file. The rules and the allowlist are tracked; a scan without them is not the gate this repository claims."

gitleaks="$(gitleaks_executable)"

failed=0

info "Scanning the working tree"
"$gitleaks" dir . \
  --config "$config_file" \
  --no-banner --redact --exit-code 1 || failed=1

if [[ -n "$range" ]]; then
  scanned="the working tree and the commits in $range"
  info "Scanning commits in $range"
  "$gitleaks" git . \
    --config "$config_file" \
    --log-opts "$range" \
    --no-banner --redact --exit-code 1 || failed=1
else
  scanned="the working tree or in history"
  info "Scanning every commit reachable from HEAD"
  "$gitleaks" git . \
    --config "$config_file" \
    --no-banner --redact --exit-code 1 || failed=1
fi

((failed == 0)) || die "$(
  cat <<'EOF'
A credential was found. Nothing has been changed.

Remove the value, rotate it, and -- if it is already committed -- rewrite the
history that carries it, because a scan that only cleans the working tree
leaves the secret reachable. If the match is a deliberate test literal, add a
narrowly scoped entry to .gitleaks.toml with a comment saying what it is and
why it is not a secret.
EOF
)"

success "No credentials found in $scanned"
