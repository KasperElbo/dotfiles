#!/usr/bin/env bash
# The freshness report over the manual-bump pins, and the gate that keeps every
# such pin declared.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

checker="$repo_root/scripts/check-pin-freshness.sh"
validator="$repo_root/scripts/validate-pin-freshness.py"

# --- The shipped manifests agree -------------------------------------------
#
# Run against the real tree first: this is the assertion that a pin added to
# config/network-sources.tsv without a way to notice it going stale fails CI,
# which is the entire reason this mechanism exists.

run_capture python3 "$validator"
assert_success
printf 'PASS: every manual-bump source in this repository declares its freshness probe\n'

# --- A stubbed remote, so no test here reaches the network ------------------
#
# The report shells out to `git ls-remote`, so a stub on PATH is the whole
# seam. It answers from files the suite writes, which is what lets a probe
# failure and an unreachable remote be exercised as deliberately as a hit.

stub_bin="$root/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
# A ls-remote stub: the answer for a URL is the file the suite named after it,
# and a URL with no file is an unreachable remote.
set -uo pipefail
[[ "${1:-}" == ls-remote ]] || exit 0
url=""
for argument in "$@"; do
  [[ "$argument" == https://* ]] && url="$argument"
done
key="${url##*/}"
answer="$STUB_REMOTE_DIR/${key}"
if [[ ! -f "$answer" ]]; then
  printf 'fatal: could not read from remote repository %s\n' "$url" >&2
  exit 128
fi
cat "$answer"
EOF_GIT
chmod +x "$stub_bin/git"

# test_manifest <path> <row>...: a freshness manifest with the standard header.
test_manifest() {
  local path="$1"
  shift
  {
    printf 'source\tprobe\ttarget\tpin_file\tpin_key\tnote\n'
    printf '%s\n' "$@"
  } >"$path"
}

remotes="$root/remotes"
mkdir -p "$remotes"
tags() {
  local name="$1"
  shift
  local tag
  : >"$remotes/$name"
  for tag in "$@"; do
    printf '%040d\trefs/tags/%s\n' 0 "$tag" >>"$remotes/$name"
  done
}

pin_file="$root/pins.sh"
cat >"$pin_file" <<'EOF_PINS'
#!/usr/bin/env bash
version="v1.2.0"
commit="1111111111111111111111111111111111111111"
duplicated="a"
duplicated="b"
EOF_PINS

tags current.git v1.0.0 v1.1.0 v1.2.0
tags moved.git v1.0.0 v1.2.0 v2.0.1
printf '2222222222222222222222222222222222222222\tHEAD\n' >"$remotes/head-moved.git"
printf '1111111111111111111111111111111111111111\tHEAD\n' >"$remotes/head-same.git"

run_report() {
  local manifest="$1"
  shift
  run_capture env \
    PATH="$stub_bin:$PATH" \
    STUB_REMOTE_DIR="$remotes" \
    PIN_FRESHNESS_MANIFEST="$manifest" \
    "$checker" "$@"
}

# --- A pin at its upstream's newest tag is current --------------------------

manifest="$root/current.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/current.git\t%s\tversion\t-' "$pin_file")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'demo'
assert_contains "$TEST_OUTPUT" 'current'
assert_not_contains "$TEST_OUTPUT" 'BEHIND'
assert_contains "$TEST_OUTPUT" '1 current, 0 behind, 0 not probed, 0 could not be checked.'
printf 'PASS: a pin at the newest upstream tag reports as current\n'

# --- A newer upstream tag is reported, and does not fail by default ---------

manifest="$root/behind.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/moved.git\t%s\tversion\t-' "$pin_file")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'BEHIND'
assert_contains "$TEST_OUTPUT" 'v2.0.1'
assert_contains "$TEST_OUTPUT" '0 current, 1 behind, 0 not probed, 0 could not be checked.'
printf 'PASS: a stale pin is reported, and the report still succeeds\n'

run_report "$manifest" --fail-on-stale
assert_failure
assert_contains "$TEST_OUTPUT" 'BEHIND'
printf 'PASS: --fail-on-stale turns a stale pin into a non-zero exit\n'

# --- A leading v is decoration on either side -------------------------------
#
# Every pin in this repository is written one of the two ways -- Handy's
# 0.9.7 against its v0.9.7 tag, Catppuccin's v2.3.0 against v2.3.0 -- so a
# comparison that read them as different strings would report every release
# pin as stale forever.

bare_pin="$root/bare.sh"
printf 'version="1.2.0"\n' >"$bare_pin"
manifest="$root/bare.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/current.git\t%s\tversion\t-' "$bare_pin")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'current'
assert_not_contains "$TEST_OUTPUT" 'BEHIND'
printf 'PASS: a bare pin and a v-prefixed tag compare as the same release\n'

# --- A hyphenated build field orders like a further dotted field ------------

tags build.git 3.1.3-1062 3.2.0-1092
netcoredbg_pin="$root/netcoredbg.sh"
printf 'legacy_version="3.1.3-1062"\n' >"$netcoredbg_pin"
manifest="$root/build.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/build.git\t%s\tlegacy_version\t-' "$netcoredbg_pin")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'BEHIND'
assert_contains "$TEST_OUTPUT" '3.2.0-1092'
printf 'PASS: a hyphenated build field is ordered, not treated as incomparable\n'

# --- A commit pin compares against the branch tip ---------------------------

manifest="$root/head-same.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-head\thttps://example.invalid/head-same.git\t%s\tcommit\t-' "$pin_file")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'current'

manifest="$root/head-moved.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-head\thttps://example.invalid/head-moved.git\t%s\tcommit\t-' "$pin_file")"
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'BEHIND'
printf 'PASS: a commit pin is compared against the branch tip\n'

# --- A probe that cannot answer fails, rather than reading as current -------
#
# The whole point of the report is that silence means "nothing to do". A
# remote it could not reach, or a pin it could not read, must therefore be
# non-zero even without --fail-on-stale: a check that skips what it cannot
# understand fails open, which is the failure mode this repository keeps
# finding in its own checkers.

manifest="$root/unreachable.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/absent.git\t%s\tversion\t-' "$pin_file")"
run_report "$manifest"
assert_failure
assert_contains "$TEST_OUTPUT" 'probe failed'
assert_contains "$TEST_OUTPUT" '0 current, 0 behind, 0 not probed, 1 could not be checked.'
printf 'PASS: an unreachable remote fails the report instead of reading as current\n'

manifest="$root/missing-pin.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/current.git\t%s\tabsent_key\t-' "$pin_file")"
run_report "$manifest"
assert_failure
assert_contains "$TEST_OUTPUT" 'pin unreadable'
assert_contains "$TEST_OUTPUT" 'no absent_key="..." assignment'
printf 'PASS: a pin the report cannot read is an error, not a skipped row\n'

manifest="$root/duplicate-pin.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/current.git\t%s\tduplicated\t-' "$pin_file")"
run_report "$manifest"
assert_failure
assert_contains "$TEST_OUTPUT" 'must state its pin once'
printf 'PASS: a file that states its pin twice is an error\n'

# --- A pin ahead of its upstream is surfaced, not silently passed -----------

tags withdrawn.git v1.0.0 v1.1.0
manifest="$root/withdrawn.tsv"
test_manifest "$manifest" \
  "$(printf 'demo\tgit-tags\thttps://example.invalid/withdrawn.git\t%s\tversion\t-' "$pin_file")"
run_report "$manifest"
assert_failure
assert_contains "$TEST_OUTPUT" 'ahead of upstream'
printf 'PASS: a pin ahead of the newest upstream tag is surfaced\n'

# --- An unprobed row states its reason in the report ------------------------

manifest="$root/none.tsv"
test_manifest "$manifest" \
  'demo	none	-	-	-	Its pin is not a ref in a git repository.'
run_report "$manifest"
assert_success
assert_contains "$TEST_OUTPUT" 'not probed'
assert_contains "$TEST_OUTPUT" 'Not probed, and why:'
assert_contains "$TEST_OUTPUT" 'Its pin is not a ref in a git repository.'
printf 'PASS: a source this report cannot ask about is visible, with its reason\n'

# --- Usage ------------------------------------------------------------------

run_report "$root/none.tsv" --no-such-option
assert_status 2
assert_contains "$TEST_OUTPUT" 'Unknown option'
printf 'PASS: an unknown option is a usage error\n'

# --- The gate: the two manifests must describe the same set of pins ---------

fixture="$root/fixture"
mkdir -p "$fixture/config" "$fixture/scripts/lib" "$fixture/installers"
cp "$repo_root/scripts/lib/manifests.py" "$fixture/scripts/lib/manifests.py"
cp "$validator" "$fixture/scripts/validate-pin-freshness.py"
printf 'pinned="v1.2.0"\n' >"$fixture/installers/pin.sh"

network_header=$'id\tcomponent\towner\tkind\turl\tprivilege\ttier\trequested\tresolved\tintegrity\tcadence\trollback\tconsumers'

# fixture_registry <cadence> <requested>
fixture_registry() {
  {
    printf '%s\n' "$network_header"
    printf 'demo\tDemo\tnobody\tgit\thttps://example.invalid/demo.git\tuser\texact-commit\t%s\tgit rev-parse HEAD\tgit-tag-pinned\t%s\tredo it\tinstallers/pin.sh\n' \
      "$2" "$1"
  } >"$fixture/config/network-sources.tsv"
}

run_fixture_validator() {
  run_capture python3 "$fixture/scripts/validate-pin-freshness.py" --root "$fixture"
}

probe_row=$'demo\tgit-tags\thttps://example.invalid/demo.git\tinstallers/pin.sh\tpinned\t-'

fixture_registry manual-bump v1.2.0
test_manifest "$fixture/config/pin-freshness.tsv" "$probe_row"
run_fixture_validator
assert_success
printf 'PASS: a declared manual-bump pin validates\n'

test_manifest "$fixture/config/pin-freshness.tsv"
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" "has cadence manual-bump but no row"
printf 'PASS: a manual-bump source with no freshness row fails the gate\n'

fixture_registry rolling v1.2.0
test_manifest "$fixture/config/pin-freshness.tsv" "$probe_row"
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" 'announces its own updates'
printf 'PASS: a freshness row for a self-announcing source fails\n'

fixture_registry manual-bump v1.2.0
test_manifest "$fixture/config/pin-freshness.tsv" \
  $'demo\tgit-tags\thttps://example.invalid/demo.git\tinstallers/pin.sh\tabsent\t-'
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" 'absent="..." 0 times'
printf 'PASS: a pin_key the installer does not state fails the gate\n'

test_manifest "$fixture/config/pin-freshness.tsv" \
  $'demo\tnone\t-\t-\t-\t-'
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" 'must say why in its note'
printf 'PASS: an unprobed source without a stated reason fails the gate\n'

test_manifest "$fixture/config/pin-freshness.tsv" \
  $'demo\tgit-tags\thttp://example.invalid/demo.git\tinstallers/pin.sh\tpinned\t-'
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" 'must be an https URL'
printf 'PASS: a probe target that is not https fails the gate\n'

# --- The registry must not drift from the installer it describes ------------

fixture_registry manual-bump v1.1.0
test_manifest "$fixture/config/pin-freshness.tsv" "$probe_row"
run_fixture_validator
assert_failure
assert_contains "$TEST_OUTPUT" "records demo as pinned to 'v1.1.0'"
assert_contains "$TEST_OUTPUT" "pins 'v1.2.0'"
printf 'PASS: a registry pin that disagrees with the installer fails the gate\n'

# A `requested` that describes the pin rather than stating it is prose, and is
# not compared: "pinned release + sha256" is how four of the real rows read.
fixture_registry manual-bump 'pinned release + sha256'
run_fixture_validator
assert_success
printf 'PASS: a prose requested value is left to the reader, not compared\n'

printf '\nAll pin freshness checks passed.\n'
