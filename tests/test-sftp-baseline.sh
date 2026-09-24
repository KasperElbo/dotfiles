#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/capabilities.sh
source "$repo_root/common/lib/capabilities.sh"

test_install_cleanup_trap

# Command-line SFTP is a base capability on every supported platform, so this
# suite has to prove two separate things, and say which one drifted:
#
#   A. implementation -- each platform provides the intended OpenSSH client
#      through its declared package/provider contract, not through whatever
#      binary happens to be on PATH.
#   B. documentation  -- the promised instructions still exist *inside the
#      SFTP section*, with usable commands in them.
#
# Both are written as functions over an input path so the same assertions can
# be re-run against a deliberately broken copy: a check that cannot be made to
# fail is not evidence of anything.

drift() {
  printf 'SFTP %s drift: %s\n' "$1" "$2" >&2
  return 1
}

# ---------------------------------------------------------------------------
# A. Implementation: declared package/provider ownership
# ---------------------------------------------------------------------------

# check_declared_package <manifest> <platform> <capability> <package>
#
# The capability manifest is the provider contract: it names the provider
# (dnf, homebrew, ...) and the exact package list. Reading it beats grepping
# an installer script, which can keep the word while losing the dependency.
check_declared_package() {
  local manifest="$1" platform="$2" capability="$3" package="$4"
  local packages

  CAPABILITY_MANIFEST="$manifest" \
    packages="$(capability_field "$platform" "$capability" packages 2>/dev/null)" ||
    drift implementation "$platform has no $capability row in $manifest" ||
    return 1

  [[ ",$packages," == *",$package,"* ]] ||
    drift implementation \
      "$platform/$capability does not declare the $package package" ||
    return 1
}

check_sftp_implementation() {
  local manifest="$1"
  local status=0

  # Fedora and Fedora/WSL get the client from the distribution's own
  # openssh-clients package, the same one that provides ssh and scp.
  local platform
  for platform in fedora fedora-wsl; do
    check_declared_package "$manifest" "$platform" base openssh-clients ||
      status=1
  done

  # macOS deliberately declares no SSH package at all: Apple's system OpenSSH
  # under /usr/bin is the provider, so a Homebrew SSH would be a second
  # implementation, not an upgrade.
  local macos_packages
  macos_packages="$(CAPABILITY_MANIFEST="$manifest" \
    capability_field macos base packages 2>/dev/null || true)"
  if [[ ",$macos_packages," == *,openssh,* ]]; then
    drift implementation \
      'macOS declares an openssh package; Apple provides the client' ||
      status=1
  fi

  return "$status"
}

printf 'A. Implementation: declared package/provider ownership\n'

check_sftp_implementation "$repo_root/config/capabilities.tsv" ||
  _test_die 'the current capability manifest must declare the SFTP provider'
printf 'PASS: every supported platform declares its OpenSSH/SFTP provider\n'

# Negative: removing the package from a supported platform's declaration must
# fail, which is what the old broad README grep could not detect.
test_new_root
mutated_manifest="$TEST_ROOT/capabilities.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" }
  $1 == "base" && $2 == "fedora" { gsub(/openssh-clients,/, "", $9) }
  { print }' "$repo_root/config/capabilities.tsv" >"$mutated_manifest"
grep -q 'openssh-clients' <<<"$(awk -F '\t' '$1 == "base" && $2 == "fedora" { print $9 }' \
  "$mutated_manifest")" &&
  _test_die 'the mutation fixture failed to remove the package'

run_capture check_sftp_implementation "$mutated_manifest"
assert_failure
assert_contains "$TEST_OUTPUT" 'does not declare the openssh-clients package'
printf 'PASS: removing the declared package from a platform fails\n'

# The verifiers must resolve ownership through the provider, not accept any
# ambient binary. Fedora asks RPM which package owns the resolved command;
# macOS requires Apple's /usr/bin client. Both run only on their own platform,
# so this asserts the contract each platform's CI then exercises for real.
fedora_verify="$repo_root/platforms/fedora/scripts/verify.sh"
assert_code_contains "$fedora_verify" "rpm -qf --queryformat '%{NAME}'"
assert_code_contains "$fedora_verify" "expected Fedora's openssh-clients"
assert_code_contains "$fedora_verify" 'for cmd in sftp scp ssh'

macos_verify="$repo_root/platforms/macos/scripts/verify.sh"
assert_code_contains "$macos_verify" 'SFTP client baseline'
assert_code_contains "$macos_verify" "Apple's system OpenSSH"
# shellcheck disable=SC2016 # Matching the literal expression in verify.sh.
assert_code_contains "$macos_verify" '/usr/bin/"$name"'

if grep -Fqi 'openssh' "$repo_root/platforms/macos/Brewfile" ||
  grep -Fqi 'filezilla' "$repo_root/platforms/macos/Brewfile"; then
  _test_die 'macOS must not install a second SSH implementation or a GUI SFTP client'
fi
printf 'PASS: verifiers prove provider ownership instead of accepting any binary\n'

# KDE's sftp:// path is reused from kio-extras rather than duplicated, and no
# platform installs a dedicated GUI client.
assert_code_contains "$repo_root/platforms/fedora/scripts/install-kde-theme.sh" \
  'kio-extras'
assert_code_contains "$fedora_verify" 'kio-extras'
for package_file in \
  "$repo_root/platforms/fedora/scripts/install-system.sh" \
  "$repo_root/platforms/fedora/scripts/install-sway.sh" \
  "$repo_root/platforms/fedora/scripts/install-desktop-tools.sh"; do
  if grep -Fqi 'filezilla' "$package_file"; then
    _test_die "$package_file must not install a dedicated GUI SFTP client"
  fi
done

if code_grep -Eq -- '--(no-)?openssh|--(no-)?sftp' \
  "$repo_root/platforms/fedora/install.sh"; then
  _test_die 'SFTP capability must not be gated behind an installer flag'
fi
printf 'PASS: SFTP is an ungated base capability with no duplicate GUI client\n'

# ---------------------------------------------------------------------------
# B. Documentation: assertions scoped to the actual SFTP section
# ---------------------------------------------------------------------------

# markdown_section <file> <title>
#
# Prints the body of the section whose heading text is <title>, ignoring the
# heading level and any "N. " ordinal (sections get renumbered), and stopping
# at the next heading. Fenced code blocks are tracked so a '#' comment inside
# an example is never mistaken for a heading.
markdown_section() {
  local file="$1" title="$2"

  awk -v want="$title" '
    /^```/ { fence = !fence; if (in_section) print; next }
    !fence && /^#+[[:space:]]/ {
      if (in_section) exit
      heading = $0
      sub(/^#+[[:space:]]*/, "", heading)
      sub(/^[0-9]+\.[[:space:]]*/, "", heading)
      if (heading == want) in_section = 1
      next
    }
    in_section { print }
  ' "$file"
}

# check_sftp_documentation <fedora-doc> <macos-doc>
#
# Asserts meaningful content *inside* the SFTP sections. The previous version
# of this suite grepped the whole README for "SFTP", "Fedora" and "macOS",
# words that occur throughout unrelated prose, so deleting the instructions
# left it green.
check_sftp_documentation() {
  local fedora_doc="$1" macos_doc="$2"
  local status=0 section needle

  section="$(markdown_section "$fedora_doc" 'SFTP client')"
  if [[ -z "${section//[[:space:]]/}" ]]; then
    drift documentation "the first-run guide has no 'SFTP client' section body" ||
      return 1
  fi

  # The documented workflow: connect, transfer non-interactively, and open the
  # GUI location. Each is a complete command, not a keyword.
  for needle in 'sftp user@host' 'scp file.txt user@host:/remote/path/' \
    'sftp://user@host/path'; do
    [[ "$section" == *"$needle"* ]] ||
      drift documentation "the first-run SFTP section no longer documents '$needle'" ||
      status=1
  done

  # The interactive command reference has to stay a reference: each command on
  # its own line inside the section's fenced block.
  for needle in ls cd lcd pwd lpwd get put mget mput mkdir rm exit; do
    grep -Fxq -- "$needle" <<<"$section" ||
      drift documentation \
        "the SFTP command reference no longer lists '$needle'" ||
      status=1
  done

  [[ "$section" == *openssh-clients* ]] ||
    drift documentation \
      'the SFTP section no longer names the openssh-clients provider' ||
    status=1

  section="$(markdown_section "$macos_doc" 'SFTP client')"
  if [[ -z "${section//[[:space:]]/}" ]]; then
    drift documentation "docs/platforms/macos.md has no 'SFTP client' section body" ||
      return 1
  fi
  # The macOS section carries what is macOS-specific — Apple's own OpenSSH
  # under /usr/bin, and the deliberate absence of a GUI client — and links to
  # the shared reference above rather than restating its command list.
  for needle in '/usr/bin' 'Finder' 'first-run.md#6-sftp-client'; do
    [[ "$section" == *"$needle"* ]] ||
      drift documentation \
        "the macOS SFTP section no longer documents '$needle'" ||
      status=1
  done

  # And it must not grow a second copy of the interactive command reference.
  if grep -Fxq -- 'lpwd' <<<"$section"; then
    drift documentation \
      'the macOS SFTP section restates the shared interactive command reference' ||
      status=1
  fi

  return "$status"
}

printf '\nB. Documentation: section-scoped content\n'

fedora_doc="$repo_root/docs/workflows/first-run.md"
macos_docs="$repo_root/docs/platforms/macos.md"

check_sftp_documentation "$fedora_doc" "$macos_docs" ||
  _test_die 'the current documentation must describe the SFTP workflow'
printf 'PASS: both SFTP documentation sections contain the documented workflow\n'

# Negative: deleting the section must fail even though "SFTP", "Fedora" and
# "macOS" still occur elsewhere in the document.
test_new_root
stripped_doc="$TEST_ROOT/first-run-no-sftp.md"
awk '
  /^```/ { fence = !fence }
  !fence && /^#+[[:space:]]/ {
    heading = $0
    sub(/^#+[[:space:]]*/, "", heading)
    sub(/^[0-9]+\.[[:space:]]*/, "", heading)
    skip = (heading == "SFTP client")
  }
  !skip { print }
' "$fedora_doc" >"$stripped_doc"

# The keywords the old test relied on are re-introduced in unrelated prose,
# which is precisely the case that used to keep it green.
cat >>"$stripped_doc" <<'EOF_PROSE'

## Unrelated section

This Fedora and macOS workstation once documented an SFTP workflow somewhere.
EOF_PROSE

for word in SFTP Fedora macOS; do
  grep -Fq -- "$word" "$stripped_doc" ||
    _test_die "the mutation fixture must keep the word '$word' elsewhere"
done

run_capture check_sftp_documentation "$stripped_doc" "$macos_docs"
assert_failure
assert_contains "$TEST_OUTPUT" "no 'SFTP client' section body"
printf 'PASS: deleting the SFTP section fails despite the words surviving elsewhere\n'

# Negative: an invalid connection command inside an intact section must fail.
broken_doc="$TEST_ROOT/first-run-broken-command.md"
sed 's/^sftp user@host$/sftp --transfer-mode=fast/' "$fedora_doc" >"$broken_doc"
run_capture check_sftp_documentation "$broken_doc" "$macos_docs"
assert_failure
assert_contains "$TEST_OUTPUT" "no longer documents 'sftp user@host'"
printf 'PASS: an invalid documented connection command fails\n'

# Negative: gutting the interactive command reference must fail.
gutted_doc="$TEST_ROOT/first-run-no-commands.md"
grep -vxF 'lcd' "$fedora_doc" | grep -vxF 'mput' >"$gutted_doc"
run_capture check_sftp_documentation "$gutted_doc" "$macos_docs"
assert_failure
assert_contains "$TEST_OUTPUT" "no longer lists 'lcd'"
printf 'PASS: removing commands from the interactive reference fails\n'

# Negative: the macOS section losing its link to the shared reference fails.
# That link is what makes trimming the duplicate command list safe.
broken_macos="$TEST_ROOT/macos-no-verify.md"
sed 's|first-run.md#6-sftp-client|first-run.md|' "$macos_docs" >"$broken_macos"
run_capture check_sftp_documentation "$fedora_doc" "$broken_macos"
assert_failure
assert_contains "$TEST_OUTPUT" \
  "macOS SFTP section no longer documents 'first-run.md#6-sftp-client'"
printf 'PASS: the macOS SFTP section is verified separately from the first-run guide\n'

printf '\nSFTP implementation-ownership and documentation-section tests passed.\n'
