#!/usr/bin/env bash
# The secret scanner's own bootstrap (#498): every step between the download
# and the first scan must be able to stop the scan.
#
# scripts/scan-secrets.sh downloads the pinned gitleaks, checks its digest,
# extracts it, moves it into the cache and makes it executable. A step that
# fails and is carried past means a gate reporting "No credentials found"
# after its own prerequisite said it had failed. That is the shape this suite
# reproduces: the real scanner, run from its real entry point in its own
# process, against a release archive and a network this suite owns.
#
# tests/test-repository-hygiene.sh covers the other half, that the pinned
# scanner, once in place, actually catches a credential.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

scanner="$repo_root/scripts/scan-secrets.sh"
pinned_version="$(sed -n 's/^version="\([^"]*\)"$/\1/p' "$scanner")"
[[ -n "$pinned_version" ]] ||
  _test_die "scripts/scan-secrets.sh no longer states its version once"

test_new_root
root="$TEST_ROOT"

# A checkout-shaped fixture, as tests/test-repository-hygiene.sh builds it: the
# script resolves its repository root from its own location, so a copy under
# $checkout scans $checkout, and the symlinks keep the libraries the tracked
# ones. The copy differs from the tracked script in its pinned digests only,
# which pin_archive rewrites to name an archive this suite built.
checkout="$root/checkout"
mkdir -p "$checkout/scripts"
ln -s "$repo_root/common" "$checkout/common"
ln -s "$repo_root/.gitleaks.toml" "$checkout/.gitleaks.toml"
git -C "$checkout" init -q .
git -C "$checkout" -c user.email=t@example.invalid -c user.name=Test \
  commit -q --allow-empty -m 'empty'

# make_archive <archive> <gitleaks-version|-> [member...]: a release archive.
# With a version, it carries a `gitleaks` that reports it and records every
# scan it is asked for in $SCAN_LOG, exiting 0 as a clean scan does. `-`
# leaves gitleaks out. Each extra member is an empty file of that name.
#
# The members are owned by uid 501 and gid 50, as upstream's are: that is the
# first macOS account, and restoring it is what failed in the report.
make_archive() {
  python3 - "$@" <<'PYTHON'
import io
import sys
import tarfile

archive, version, *others = sys.argv[1:]
members = []
if version != "-":
    members.append((
        "gitleaks",
        (
            "#!/bin/sh\n"
            'if [ "$1" = version ]; then\n'
            f"  printf '%s\\n' '{version}'\n"
            "  exit 0\n"
            "fi\n"
            'printf \'%s\\n\' "$*" >>"$SCAN_LOG"\n'
        ).encode(),
    ))
members.extend((name, b"") for name in others)

with tarfile.open(archive, "w:gz") as out:
    for name, data in members:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o755
        info.uid, info.gid = 501, 50
        info.uname, info.gname = "upstream", "staff"
        out.addfile(info, io.BytesIO(data))
PYTHON
}

# archive_digest <archive>: its SHA-256, computed the way the host can.
archive_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | cut -d' ' -f1
  else
    shasum -a 256 -- "$1" | cut -d' ' -f1
  fi
}

# pin_archive <archive>: the fixture scanner, pinned to <archive> on every
# platform, so whichever one runs this suite takes the download path.
pin_archive() {
  local digest
  digest="$(archive_digest "$1")"
  sed "s/^\(sha256_[a-z0-9_]*\)=\"[0-9a-f]\{64\}\"$/\1=\"$digest\"/" \
    "$scanner" >"$checkout/scripts/scan-secrets.sh"
  chmod +x "$checkout/scripts/scan-secrets.sh"
  [[ "$(grep -c "^sha256_[a-z0-9_]*=\"$digest\"$" "$checkout/scripts/scan-secrets.sh")" == 4 ]] ||
    _test_die "pin_archive: scripts/scan-secrets.sh no longer pins four digests one per line"
}

release="$root/release"
mkdir -p "$release"
make_archive "$release/good.tar.gz" "$pinned_version"
make_archive "$release/other.tar.gz" "$pinned_version" README.md
make_archive "$release/empty.tar.gz" -
make_archive "$release/no-binary.tar.gz" - LICENSE README.md
make_archive "$release/wrong-version.tar.gz" 0.0.0

# --- The network and the fallible commands, under this suite's control -----
#
# curl serves $SERVE_ARCHIVE for the pinned release URL and nothing else, and
# refuses outright when $CURL_OFFLINE is set, so a run that had to download is
# told apart from one that used its cache. tar, mv and chmod are the real ones
# unless a case asks for the failure it is about: tar can do all of its work
# and still exit non-zero, which is the shape reported in #498.
bin="$root/stubs"
mkdir -p "$bin"
real_tar="$(type -P tar)"
real_mv="$(type -P mv)"
real_chmod="$(type -P chmod)"
real_uname="$(type -P uname)"

cat >"$bin/curl" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >>"$root/curl.log"
[[ -z "\${CURL_OFFLINE:-}" ]] || exit 7
output="" url=""
while ((\$#)); do
  case "\$1" in
  --output) output="\$2"; shift 2 ;;
  --) url="\$2"; shift 2 ;;
  *) shift ;;
  esac
done
case "\$url" in
https://github.com/gitleaks/gitleaks/releases/download/v$pinned_version/gitleaks_${pinned_version}_*.tar.gz)
  exec cp -- "\$SERVE_ARCHIVE" "\$output"
  ;;
esac
printf 'curl fixture: no such release asset: %s\n' "\$url" >&2
exit 22
EOF

cat >"$bin/tar" <<EOF
#!/usr/bin/env bash
status=0
"$real_tar" "\$@" || status=\$?
exit "\${TAR_STATUS:-\$status}"
EOF

# The cache entry is the only destination either failure is aimed at, so the
# libraries' own mv and chmod calls elsewhere are untouched.
cat >"$bin/mv" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAIL_MV:-}" && "\${*: -1}" == "\$FAIL_MV" ]]; then
  printf 'mv fixture: refusing to write %s\n' "\$FAIL_MV" >&2
  exit 1
fi
exec "$real_mv" "\$@"
EOF

cat >"$bin/chmod" <<EOF
#!/usr/bin/env bash
if [[ -n "\${FAIL_CHMOD:-}" && "\${1:-}" == 0755 ]]; then
  printf 'chmod fixture: refusing %s\n' "\$*" >&2
  exit 1
fi
exec "$real_chmod" "\$@"
EOF

cat >"$bin/uname" <<EOF
#!/usr/bin/env bash
if [[ -n "\${UNAME_MACHINE:-}" && "\$*" == -m ]]; then
  printf '%s\n' "\$UNAME_MACHINE"
  exit 0
fi
exec "$real_uname" "\$@"
EOF

chmod +x "$bin"/*

sha_tools=()
for tool in sha256sum shasum; do
  if command -v "$tool" >/dev/null 2>&1; then
    sha_tools+=("$tool")
  fi
done
test_isolate_path gzip "${sha_tools[@]}"
PATH="$bin:$PATH"

cache_root="$root/cache"
cache="$cache_root/dotfiles/gitleaks/$pinned_version"
binary="$cache/gitleaks"

# scan [VAR=value...]: the fixture scanner from a clean slate. Only the
# variables a case names reach it, so DOTFILES_GITLEAKS from the calling
# environment can never stand in for the download under test.
scan() {
  : >"$root/scan.log"
  : >"$root/curl.log"
  run_capture env -i \
    PATH="$PATH" HOME="$root/home" XDG_CACHE_HOME="$cache_root" \
    TMPDIR="$root/tmp" SCAN_LOG="$root/scan.log" \
    SERVE_ARCHIVE="$release/good.tar.gz" DOTFILES_FETCH_ATTEMPTS=1 \
    "$@" "$checkout/scripts/scan-secrets.sh"
}

clear_cache() {
  rm -rf -- "$cache_root" "$root/tmp"
  mkdir -p "$cache_root" "$root/tmp"
}

# assert_stopped_before_scanning <label>: the run failed, gitleaks was never
# asked to scan anything, and nothing is left behind that a later run could
# take for the pinned scanner.
assert_stopped_before_scanning() {
  assert_failure
  assert_not_contains "$TEST_OUTPUT" 'No credentials found'
  [[ ! -s "$root/scan.log" ]] ||
    _test_die "$1: gitleaks was asked to scan after the bootstrap failed: $(cat "$root/scan.log")"
  assert_path_missing "$binary"
  if [[ -d "$cache" ]]; then
    local leftover
    leftover="$(find "$cache" -mindepth 1 -print)"
    [[ -z "$leftover" ]] ||
      _test_die "$1: a failed bootstrap left this in the cache: $leftover"
  fi
  if [[ -d "$root/tmp" ]]; then
    local staged
    staged="$(find "$root/tmp" -mindepth 1 -print)"
    [[ -z "$staged" ]] ||
      _test_die "$1: a failed bootstrap left this in TMPDIR: $staged"
  fi
}

# --- A clean cache downloads, installs and scans ---------------------------

clear_cache
pin_archive "$release/good.tar.gz"
scan
assert_success
assert_contains "$TEST_OUTPUT" 'No credentials found in the working tree or in history'
assert_path_executable "$binary"
printf 'PASS: a clean cache downloads the pinned scanner and scans with it\n'

# Both scans, and the history one over everything reachable: a range is only
# ever what --range asks for.
assert_file_line "$root/scan.log" \
  "dir . --config $checkout/.gitleaks.toml --ignore-gitleaks-allow --no-banner --redact --exit-code 1"
assert_file_line "$root/scan.log" \
  "git . --config $checkout/.gitleaks.toml --ignore-gitleaks-allow --no-banner --redact --exit-code 1"
assert_file_not_contains "$root/scan.log" '--log-opts'
printf 'PASS: a downloaded scanner scans the working tree and all reachable history\n'

# The archive's owner is upstream's build account. Restoring it is what fails
# as root on a filesystem that cannot represent it, and where it succeeds it
# hands the executable the gate trusts to whoever holds uid 501 here.
[[ -n "$(find "$binary" -user "$(id -u)" -print)" ]] ||
  _test_die "the cached scanner is not owned by the user who downloaded it: $(ls -ln "$binary")"
assert_not_contains "$TEST_OUTPUT" 'Cannot change ownership'
printf 'PASS: the cached scanner belongs to the user who ran the scan, not the archive\n'

# A second run takes the cache and never reaches the network.
scan CURL_OFFLINE=1
assert_success
[[ ! -s "$root/curl.log" ]] || _test_die "a cached scanner was downloaded again"
printf 'PASS: a cached scanner is reused without a download\n'

# --- tar extracts the binary and still fails (#498) ------------------------
#
# The negative control has to be this shape. A tar that writes nothing is
# caught by the version probe whatever happens to tar's status; one that
# writes the right binary and then fails is caught only by reading that
# status.
clear_cache
scan TAR_STATUS=2
assert_stopped_before_scanning 'tar failed after extracting'
printf 'PASS: tar exiting non-zero after extracting gitleaks stops the scan\n'

# And nothing from that run is taken for the pinned scanner later: offline,
# the next run has to download again, so it fails.
scan CURL_OFFLINE=1
assert_failure
[[ -s "$root/curl.log" ]] ||
  _test_die "a run after a failed extraction did not try to download: $TEST_OUTPUT"
[[ ! -s "$root/scan.log" ]] ||
  _test_die "a run after a failed extraction scanned with what it left behind"
printf 'PASS: a failed extraction leaves nothing a later run accepts\n'

# --- Every other step stops before scanning ---------------------------------

clear_cache
scan SERVE_ARCHIVE="$release/other.tar.gz"
assert_stopped_before_scanning 'wrong digest'
assert_contains "$TEST_OUTPUT" 'SHA-256 mismatch'
printf 'PASS: an archive with the wrong digest stops the scan\n'

clear_cache
pin_archive "$release/empty.tar.gz"
scan SERVE_ARCHIVE="$release/empty.tar.gz"
assert_stopped_before_scanning 'empty archive'
printf 'PASS: an empty archive stops the scan\n'

clear_cache
pin_archive "$release/no-binary.tar.gz"
scan SERVE_ARCHIVE="$release/no-binary.tar.gz"
assert_stopped_before_scanning 'archive without gitleaks'
printf 'PASS: an archive without gitleaks in it stops the scan\n'

clear_cache
pin_archive "$release/wrong-version.tar.gz"
scan SERVE_ARCHIVE="$release/wrong-version.tar.gz"
assert_stopped_before_scanning 'wrong version'
assert_contains "$TEST_OUTPUT" "does not report $pinned_version"
printf 'PASS: a downloaded scanner reporting another version stops the scan\n'

clear_cache
pin_archive "$release/good.tar.gz"
scan FAIL_MV="$binary"
assert_stopped_before_scanning 'failed move'
printf 'PASS: a failed move into the cache stops the scan\n'

clear_cache
scan FAIL_CHMOD=1
assert_stopped_before_scanning 'failed chmod'
printf 'PASS: a failed chmod stops the scan\n'

# An unsupported platform is refused before anything is fetched, rather than
# carried on with an empty asset name into a download that cannot succeed.
clear_cache
scan UNAME_MACHINE=sparc64
assert_stopped_before_scanning 'unsupported platform'
assert_contains "$TEST_OUTPUT" 'No pinned gitleaks build for'
[[ ! -s "$root/curl.log" ]] ||
  _test_die "an unsupported platform still reached the network: $(cat "$root/curl.log")"
printf 'PASS: an unsupported platform is refused before any download\n'
