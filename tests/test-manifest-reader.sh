#!/usr/bin/env bash
# The shell reader every registry goes through at install and verify time.
#
# `common/lib/manifest.sh` is the single read path for config/capabilities.tsv,
# install-options.tsv, command-providers.tsv, tool-floors.tsv, pin-freshness.tsv
# and actions.tsv from shell, and it had no suite of its own: the only test that
# reached it did so incidentally, through capability_field. It also disagreed
# with the tested Python reader about a malformed row. Given a header of three
# columns and a data row of two, `scripts/lib/manifests.py` refuses the file and
# this reader printed an empty value and returned 0 -- so a truncated `packages`
# column read as "this capability installs nothing" and the installer reported
# success. The Python validator runs in CI; this file runs on a user's machine
# during ./install.sh and platforms/*/scripts/verify.sh, where nothing validates
# anything (issue #387, NC-05).
#
# Every case below runs the real library against a fixture, so what is asserted
# is the reader's answer and exit status, not the shape of its source.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
# shellcheck source=../common/lib/manifest.sh
source "$repo_root/common/lib/manifest.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# fixture <name> <line>...: a TSV written from the lines given, tabs and all.
fixture() {
  local name="$1"
  shift
  local path="$root/$name"
  printf '%s\n' "$@" >"$path"
  printf '%s' "$path"
}

good="$(fixture good.tsv \
  $'platform\tcapability\tpackages' \
  $'fedora\tbase\tgit,stow' \
  $'fedora\tkde\tplasma' \
  $'macos\tbase\tgit')"

# ---------------------------------------------------------------------------
# What a well-formed manifest answers

run_capture manifest_values "$good" packages platform fedora
assert_success
assert_eq $'git,stow\nplasma' "$TEST_OUTPUT"
printf 'PASS: manifest_values returns every matching row, in manifest order\n'

run_capture manifest_field "$good" packages platform fedora
assert_success
assert_eq 'git,stow' "$TEST_OUTPUT"
printf 'PASS: manifest_field returns the first matching row only\n'

run_capture manifest_values "$good" capability,packages platform fedora capability kde
assert_success
assert_eq $'kde\tplasma' "$TEST_OUTPUT"
printf 'PASS: several key columns narrow the match, and fields come back tab-joined\n'

run_capture manifest_values "$good" packages platform openbsd
assert_success
assert_eq '' "$TEST_OUTPUT"
printf 'PASS: manifest_values treats no matching row as an empty answer, not an error\n'

run_capture manifest_field "$good" packages platform openbsd
assert_status 1
assert_eq '' "$TEST_OUTPUT"
printf 'PASS: manifest_field returns 1 when nothing matches\n'

# The ENVIRON indirection in the library exists so that a value is not read as
# an awk escape sequence. `awk -v` would turn this into a tab.
escapes="$(fixture escapes.tsv \
  $'id\tsource_pattern' \
  $'dictation\t\\tliteral\\nbackslashes')"
run_capture manifest_field "$escapes" source_pattern id dictation
assert_success
assert_eq '\tliteral\nbackslashes' "$TEST_OUTPUT"
printf 'PASS: a backslash in a value survives the read as itself\n'

run_capture manifest_field "$escapes" source_pattern source_pattern '\tliteral\nbackslashes'
assert_success
assert_eq '\tliteral\nbackslashes' "$TEST_OUTPUT"
printf 'PASS: a backslash in a key value matches as itself\n'

# ---------------------------------------------------------------------------
# A row that does not carry every column

# This is the case the two readers disagreed about, and the reason this suite
# exists. Against the reader before the fix, both of these return 0 and print
# an empty value.
short="$(fixture short.tsv \
  $'platform\tcapability\tpackages' \
  $'fedora\tbase\tgit,stow' \
  $'fedora\tkde')"
run_capture manifest_values "$short" packages platform fedora capability kde
assert_failure
assert_status 2
assert_contains "$TEST_OUTPUT" 'line 3: columns packages are missing'
assert_contains "$TEST_OUTPUT" 'a row must carry every one of the 3 columns'
assert_not_contains "$TEST_OUTPUT" 'is past the last column'
printf 'PASS: a short row fails with the line and the columns it lacks\n'

long="$(fixture long.tsv \
  $'platform\tcapability\tpackages' \
  $'fedora\tbase\tgit,stow\tsurplus')"
run_capture manifest_values "$long" packages platform fedora
assert_failure
assert_status 2
assert_contains "$TEST_OUTPUT" 'line 2: 4 columns, expected 3'
assert_contains "$TEST_OUTPUT" 'surplus is past the last column'
printf 'PASS: a row with a surplus column fails and names what is past the end\n'

# The guard does not stop guarding once the caller has its answer. manifest_field
# used to exit at the first match, which would have left every row below it
# unread -- the shape of defect where a check silently narrows its own scope.
run_capture manifest_field "$short" packages platform fedora capability base
assert_status 2
assert_contains "$TEST_OUTPUT" 'line 3: columns packages are missing'
printf 'PASS: manifest_field checks arity past its own match, not up to it\n'

# ---------------------------------------------------------------------------
# Headers the reader refuses

duplicate="$(fixture duplicate.tsv \
  $'platform\tcapability\tplatform' \
  $'fedora\tbase\tfedora')"
run_capture manifest_values "$duplicate" capability
assert_status 2
assert_contains "$TEST_OUTPUT" 'repeats column: platform'
printf 'PASS: a header repeating a column is refused, and names it\n'

run_capture manifest_values "$good" nosuchfield
assert_status 2
assert_contains "$TEST_OUTPUT" 'has no column: nosuchfield'
printf 'PASS: a requested column the header lacks is refused, and names it\n'

run_capture manifest_values "$good" packages nosuchkey fedora
assert_status 2
assert_contains "$TEST_OUTPUT" 'has no column: nosuchkey'
printf 'PASS: a key column the header lacks is refused, and names it\n'

run_capture manifest_values "$good" packages platform
assert_status 2
assert_contains "$TEST_OUTPUT" 'names a key column without a value'
printf 'PASS: an odd number of key arguments is refused before the file is read\n'

: >"$root/empty.tsv"
run_capture manifest_values "$root/empty.tsv" packages
assert_status 2
assert_contains "$TEST_OUTPUT" 'is empty: it has no header row'
printf 'PASS: an empty manifest is refused rather than read as no rows\n'

run_capture manifest_values "$root/absent.tsv" packages
assert_status 2
printf 'PASS: a manifest that does not exist fails rather than answering nothing\n'

# A header and nothing else is well-formed, and the two entry points differ on
# it exactly as they differ on a manifest where nothing matches.
header_only="$(fixture header-only.tsv $'platform\tcapability\tpackages')"
run_capture manifest_values "$header_only" packages
assert_success
assert_eq '' "$TEST_OUTPUT"
run_capture manifest_field "$header_only" packages
assert_status 1
assert_eq '' "$TEST_OUTPUT"
printf 'PASS: a header-only manifest is empty to manifest_values and absent to manifest_field\n'

# ---------------------------------------------------------------------------
# What that means for a caller

# capability_packages is the site the finding names: a truncated packages column
# used to make it print nothing, so the installer installed nothing for that
# capability and reported success.
truncated="$root/capabilities-truncated.tsv"
python3 - "$repo_root/config/capabilities.tsv" "$truncated" <<'PYTHON'
import pathlib
import sys

source, target = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
lines = source.read_text(encoding="utf-8").splitlines()
header = lines[0].split("\t")
# Located by header name, not by position: this fixture must keep pointing at
# the same row after a column reorder, which is the very thing the reader it
# tests exists to survive.
platform, capability = (header.index("platform"), header.index("capability"))
for index, line in enumerate(lines[1:], 1):
    fields = line.split("\t")
    if fields[platform] == "fedora" and fields[capability] == "base":
        lines[index] = "\t".join(fields[:-1])
        break
else:
    raise SystemExit("config/capabilities.tsv no longer has a fedora base row to truncate")
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON

run_capture env "CAPABILITY_MANIFEST=$truncated" bash -c \
  'source "$0/common/lib/capabilities.sh"; capability_packages fedora base' "$repo_root"
assert_failure
assert_contains "$TEST_OUTPUT" 'are missing'
assert_not_contains "$TEST_OUTPUT" 'stow'
printf 'PASS: a truncated capability row fails the installer loudly instead of reading as no packages\n'

# And the tracked registries themselves satisfy the rule, so the check is not
# one this repository's own data would trip over.
for manifest in capabilities install-options command-providers tool-floors pin-freshness actions; do
  path="$repo_root/config/$manifest.tsv"
  [[ -f "$path" ]] || _test_die "config/$manifest.tsv is gone; this loop is asserting nothing"
  header="$(head -n 1 "$path")"
  first_column="${header%%$'\t'*}"
  run_capture manifest_values "$path" "$first_column"
  assert_success
  [[ -n "$TEST_OUTPUT" ]] ||
    _test_die "config/$manifest.tsv read as no rows, so this case proves nothing"
done
printf 'PASS: every registry read through this library satisfies the column-count rule\n'

printf 'Manifest reader checks passed.\n'
