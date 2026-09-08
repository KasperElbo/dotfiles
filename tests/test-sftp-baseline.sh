#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'SFTP baseline test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local value="$2"

  grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

# --- CLI SFTP is a base-package dependency, not an optional flag -----------

fedora_install_system="$repo_root/platforms/fedora/scripts/install-system.sh"
assert_contains "$fedora_install_system" '  openssh-clients'

if grep -Eq -- '--(no-)?openssh|--(no-)?sftp' \
  "$repo_root/platforms/fedora/install.sh"; then
  fail "SFTP capability must not be gated behind an installer flag"
fi

# --- verify.sh checks command-line SFTP and package ownership --------------

fedora_verify="$repo_root/platforms/fedora/scripts/verify.sh"
for cmd in scp sftp ssh; do
  assert_contains "$fedora_verify" "  $cmd"
done
assert_contains "$fedora_verify" 'openssh-clients'
assert_contains "$fedora_verify" "ssh -V"

# --- KDE's Dolphin/KIO sftp:// path is reused, not duplicated --------------

assert_contains "$fedora_verify" 'plasmashell'
assert_contains "$fedora_verify" 'dolphin'
assert_contains "$fedora_verify" 'kio-extras'
assert_contains "$repo_root/platforms/fedora/scripts/install-kde-theme.sh" \
  'kio-extras'

# No dedicated GUI SFTP client (e.g. FileZilla) is installed for KDE or Sway.
for package_file in \
  "$fedora_install_system" \
  "$repo_root/platforms/fedora/scripts/install-sway.sh" \
  "$repo_root/platforms/fedora/scripts/install-desktop-tools.sh"; do
  if grep -Fqi 'filezilla' "$package_file"; then
    fail "$package_file must not install a dedicated GUI SFTP client"
  fi
done

# --- macOS reuses Apple's built-in OpenSSH; no Homebrew SSH package ---------

macos_verify="$repo_root/platforms/macos/scripts/verify.sh"
for cmd in scp sftp ssh; do
  assert_contains "$macos_verify" "$cmd"
done

if grep -Fqi 'openssh' "$repo_root/platforms/macos/Brewfile" ||
  grep -Fqi 'filezilla' "$repo_root/platforms/macos/Brewfile"; then
  fail "macOS must not install a second SSH implementation or a dedicated GUI SFTP client"
fi

# --- documentation covers the CLI workflow and GUI integration decisions ---

readme="$repo_root/README.md"
assert_contains "$readme" '## 7. SFTP client'
assert_contains "$readme" 'sftp user@host'
assert_contains "$readme" 'sftp://user@host/path'
for interactive_command in ls cd lcd pwd lpwd get put mget mput mkdir rm exit; do
  assert_contains "$readme" "$interactive_command"
done

macos_docs="$repo_root/docs/macos.md"
assert_contains "$macos_docs" 'sftp user@host'
assert_contains "$macos_docs" 'command -v sftp'

printf 'SFTP baseline package, verification, and documentation checks passed.\n'
