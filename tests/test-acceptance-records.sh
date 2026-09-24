#!/usr/bin/env bash
# Manual acceptance records and their checklists.
#
# Every negative case below starts from a fixture record that passes, and
# introduces exactly one defect, so a rule that quietly stops working fails
# here instead of passing vacuously. The fixture is its own Git repository
# under the test root, with an empty global Git configuration, so neither the
# machine's history nor its Git settings reach the validator.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git python3

validator="$repo_root/scripts/validate-acceptance-records.py"

test_new_root
suite_root="$TEST_ROOT"
: >"$suite_root/gitconfig"
export HOME="$suite_root/home"
export GIT_CONFIG_GLOBAL="$suite_root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_AUTHOR_DATE=2026-01-15T12:00:00+00:00
export GIT_COMMITTER_DATE=2026-01-15T12:00:00+00:00

# replace_in FILE OLD NEW: replace one exact occurrence, and fail if there is
# none, so a case whose defect was never introduced cannot pass.
replace_in() {
  python3 - "$@" <<'PY'
import pathlib, sys
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
if old not in text:
    sys.exit(f"replace_in: {old!r} is not in {path}")
path.write_text(text.replace(old, new, 1))
PY
}

write_checklist() {
  cat >"$1" <<'EOF'
# Demo checklist

## Items

### DEM-01 First boundary

- **Boundary:** something no runner can see.
- **Applies when:** always.
- **Do:** look at it.
- **Pass when:** it is there.

### DEM-02 Second boundary

- **Boundary:** something optional.
- **Applies when:** `--demo` is selected.
- **Do:**

  ```bash
  ./install.sh --platform fedora --sway
  ```

- **Pass when:** it works.

## Results table

| ID | Outcome | Notes |
|---|---|---|
| DEM-01 | | |
| DEM-02 | | |
EOF
}

default_results='| DEM-01 | pass | |
| DEM-02 | not applicable | `--demo` was not selected |'

# write_record DATE SHA CHECKLIST [RESULTS] [NAME-SHA]: write a record and set
# $record to its path. The file name is derived from the same values, so a case
# changes one thing about the record and nothing else.
write_record() {
  local date="$1" sha="$2" checklist="$3" results="${4:-$default_results}"
  local short="${5:-${sha:0:7}}"
  record="$acceptance/records/$date-$checklist-$short.md"
  mkdir -p "$acceptance/records"
  cat >"$record" <<EOF
# Manual acceptance record: demo $date

## Record

| Field | Value |
|---|---|
| Checklist | \`$checklist.md\` |
| Commit | \`$sha\` |
| Date | \`$date\` |
| Hardware | Example laptop X1 |
| Firmware | X1.301 |
| Operating system | Example OS 44 |
| Kernel version | 6.6.87.2-microsoft-standard-WSL2 |
| Installer command | \`./install.sh --platform fedora --sway\` |
| Selected options | theme:macchiato,sway:true |

## Commands

\`\`\`text
./install.sh --platform fedora --sway
ssh -T git@github.com
cat ~/.config/dotfiles/hardware.conf
\`\`\`

## Results

| ID | Outcome | Notes |
|---|---|---|
$results

## Known exclusions

The documentation-range address 192.0.2.10 was used for the demo service.
EOF
}

# new_tree: a fixture repository with one committed checklist and a record of
# that commit which passes every rule. Sets $tree, $acceptance, $sha, $record.
new_tree() {
  test_new_root
  tree="$TEST_ROOT/tree"
  acceptance="$tree/docs/testing/manual-acceptance"
  mkdir -p "$acceptance"
  git -C "$tree" init --quiet --initial-branch=main
  write_checklist "$acceptance/demo.md"
  git -C "$tree" add -A
  git -C "$tree" commit --quiet -m "Add the demo checklist"
  sha="$(git -C "$tree" rev-parse HEAD)"
  write_record 2026-02-01 "$sha" demo
}

validate() {
  run_capture python3 "$validator" --root "$tree"
}

# --- Positive controls -----------------------------------------------------

run_capture python3 "$validator"
assert_success
printf 'PASS: this repository'"'"'s checklists and records satisfy the rules\n'

new_tree
validate
assert_success
assert_not_contains "$TEST_OUTPUT" "NOT OBSERVED"
printf 'PASS: a complete record of a commit in the history passes\n'

# The exemptions hold: a four-part kernel version in a version row, the
# git@github.com login, a documentation-range address and a ~ path are all in
# that record, so none of them is refused.
assert_file_contains "$record" "6.6.87.2-microsoft"
assert_file_contains "$record" "git@github.com"
assert_file_contains "$record" "192.0.2.10"
printf 'PASS: version numbers, the GitHub SSH login and documentation addresses are allowed\n'

# --- The record names what was tested --------------------------------------

new_tree
rm -- "$record"
write_record 2026-02-01 "${sha:0:12}" demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "full 40-character lowercase SHA"
printf 'PASS: an abbreviated commit SHA fails\n'

new_tree
rm -- "$record"
write_record 2026-02-01 0123456789abcdef0123456789abcdef01234567 demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "does not exist in this repository's history"
printf 'PASS: a well-formed SHA that is not in the history fails\n'

new_tree
git -C "$tree" switch --quiet -c side
printf 'side\n' >"$tree/side.txt"
git -C "$tree" add side.txt
git -C "$tree" commit --quiet -m "A commit that never reaches main"
side_sha="$(git -C "$tree" rev-parse HEAD)"
git -C "$tree" switch --quiet main
rm -- "$record"
write_record 2026-02-01 "$side_sha" demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "is not an ancestor of HEAD"
printf 'PASS: a commit on another branch fails\n'

# A shallow clone cannot answer the ancestry question, and must say so rather
# than pass as though it had been checked.
new_tree
first_sha="$sha"
printf 'second\n' >"$tree/second.txt"
git -C "$tree" add second.txt
git -C "$tree" commit --quiet -m "A second commit"
rm -- "$record"
shallow="$TEST_ROOT/shallow"
git clone --quiet --depth 1 "file://$tree" "$shallow"
acceptance="$shallow/docs/testing/manual-acceptance"
write_record 2026-02-01 "$first_sha" demo
run_capture python3 "$validator" --root "$shallow"
assert_success
assert_contains "$TEST_OUTPUT" "NOT OBSERVED"
assert_contains "$TEST_OUTPUT" "shallow clone"
printf 'PASS: a shallow clone reports the commit as not checked rather than passing silently\n'

new_tree
rm -- "$record"
write_record 2026-02-30 "$sha" demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "not a real calendar date"
printf 'PASS: a date that is not a real day fails\n'

new_tree
rm -- "$record"
write_record 2999-01-01 "$sha" demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "is in the future"
printf 'PASS: a future date fails\n'

new_tree
rm -- "$record"
write_record 2026-01-01 "$sha" demo
validate
assert_failure
assert_contains "$TEST_OUTPUT" "before its commit was made"
printf 'PASS: a record dated before its commit fails\n'

new_tree
replace_in "$record" "| Operating system | Example OS 44 |" "| Operating system |  |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "Record field 'Operating system' is empty"
printf 'PASS: an empty required field fails\n'

new_tree
replace_in "$record" "| Firmware | X1.301 |" ""
validate
assert_failure
assert_contains "$TEST_OUTPUT" "Record table has no 'Firmware' field"
printf 'PASS: a missing required field fails\n'

new_tree
replace_in "$record" "## Known exclusions" "## Other notes"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "no '## Known exclusions' section"
printf 'PASS: a missing required section fails\n'

new_tree
replace_in "$record" '`demo.md`' '`missing.md`'
mv -- "$record" "${record/-demo-/-missing-}"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "Checklist missing.md is not a checklist here"
printf 'PASS: a record naming a checklist that does not exist fails\n'

# An unfilled copy of the real template is the most likely wrong record of all.
new_tree
rm -- "$record"
mkdir -p "$acceptance/records"
cp -- "$repo_root/docs/testing/manual-acceptance/template.md" \
  "$acceptance/records/2026-02-01-demo-${sha:0:7}.md"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "Record field 'Commit' still holds a template placeholder"
assert_contains "$TEST_OUTPUT" "Record field 'Date' still holds a template placeholder"
printf 'PASS: an unfilled copy of the template fails\n'

# --- The file name agrees with the record ----------------------------------

new_tree
rm -- "$record"
write_record 2026-02-01 "$sha" demo "$default_results" abcdef0
validate
assert_failure
assert_contains "$TEST_OUTPUT" "is not a prefix of Commit"
printf 'PASS: a file name naming another commit fails\n'

new_tree
mv -- "$record" "${record/2026-02-01/2026-02-02}"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "does not match Date 2026-02-01"
printf 'PASS: a file name naming another date fails\n'

new_tree
mv -- "$record" "$acceptance/records/demo-record.md"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "record file name must be"
printf 'PASS: a file name outside the convention fails\n'

new_tree
printf 'not a record\n' >"$acceptance/records/notes.txt"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "records/ may hold only record .md files"
printf 'PASS: a stray non-record file fails\n'

# --- Every item has exactly one verdict ------------------------------------

for bad in skipped ok passed N/A PASS; do
  new_tree
  replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | $bad | a note |"
  validate
  assert_failure
  assert_contains "$TEST_OUTPUT" "DEM-01: outcome must be one of pass, fail, not observed, not applicable"
done
printf 'PASS: an outcome outside the four words fails, including a capitalised one\n'

new_tree
replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | | |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "(it is empty)"
printf 'PASS: an item with no outcome fails\n'

for outcome in fail "not observed" "not applicable"; do
  new_tree
  replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | $outcome | |"
  validate
  assert_failure
  assert_contains "$TEST_OUTPUT" "a '$outcome' outcome needs a note"
done
printf 'PASS: every outcome other than pass needs a note\n'

new_tree
replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | fail | reported as a bug |"
validate
assert_success
printf 'PASS: a recorded failure with its note is a valid record\n'

new_tree
replace_in "$record" '| DEM-02 | not applicable | `--demo` was not selected |' ""
validate
assert_failure
assert_contains "$TEST_OUTPUT" "no result for DEM-02"
printf 'PASS: a record missing an item fails\n'

new_tree
replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | pass | |
| DEM-01 | fail | seen later |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "DEM-01 has more than one result"
printf 'PASS: an item with two results fails\n'

new_tree
replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | pass | |
| DEM-09 | pass | |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "DEM-09 is not an item of the checklist"
printf 'PASS: a result for an item the checklist does not have fails\n'

new_tree
replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | pass | a | b |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "row has 4 cells, expected 3"
printf 'PASS: a results row that does not parse fails rather than being skipped\n'

# The verdict agrees with the record's own selection (#539, V5-18). DEM-02
# applies when `--demo` is selected, and the fixture's command selects only
# --sway. The obvious contradiction: DEM-02 passed anyway.
new_tree
replace_in "$record" '| DEM-02 | not applicable | `--demo` was not selected |' '| DEM-02 | pass | |'
validate
assert_failure
assert_contains "$TEST_OUTPUT" "DEM-02 applies when '\`--demo\` is selected.', which this record's installer command and selected options do not meet"
printf 'PASS: a pass for an item the record'"'"'s own selection excludes fails\n'

# The subtle one: the command names an option that merely starts with the
# item's, and the selection turns the item's own option off by name.
new_tree
replace_in "$record" '| DEM-02 | not applicable | `--demo` was not selected |' '| DEM-02 | pass | |'
replace_in "$record" '| Installer command | `./install.sh --platform fedora --sway` |' \
  '| Installer command | `./install.sh --platform fedora --sway --demo-extras` |'
replace_in "$record" '| Selected options | theme:macchiato,sway:true |' \
  '| Selected options | theme:macchiato,sway:true,demo:false |'
validate
assert_failure
assert_contains "$TEST_OUTPUT" 'DEM-02 applies when'
printf 'PASS: an option that only shares a prefix, or is recorded false, does not select the item\n'

# And the other direction: the option was selected, so "not applicable" is a
# verdict of convenience. PowerShell spells a switch in any case.
new_tree
replace_in "$acceptance/demo.md" '`--demo` is selected' '`-Demo` is selected'
git -C "$tree" commit --quiet -am "Spell the option the PowerShell way"
sha="$(git -C "$tree" rev-parse HEAD)"
rm -- "$record"
write_record 2026-02-01 "$sha" demo
replace_in "$record" '| Installer command | `./install.sh --platform fedora --sway` |' \
  '| Installer command | `.\install.ps1 -demo` |'
validate
assert_failure
assert_contains "$TEST_OUTPUT" "which this record's installer command and selected options meet, so it cannot be 'not applicable'"
replace_in "$record" '| DEM-02 | not applicable | `--demo` was not selected |' '| DEM-02 | pass | |'
validate
assert_success
printf 'PASS: an item the selection makes applicable cannot be marked not applicable\n'

# --- Nothing personal ------------------------------------------------------

# privacy_case KIND TEXT: TEXT in the notes of an otherwise valid record must
# fail, name KIND, and not be repeated in the report.
privacy_case() {
  local kind="$1" text="$2"
  new_tree
  replace_in "$record" "| DEM-01 | pass | |" "| DEM-01 | pass | $text |"
  validate
  assert_failure
  assert_contains "$TEST_OUTPUT" "contains $kind"
  assert_not_contains "$TEST_OUTPUT" "$text"
}

# Assembled from parts so this file itself contains none of these shapes whole.
at='@'
privacy_case "an email address" "signed in as someone${at}example.com"
privacy_case "a MAC address" "wifi 3c:22:fb:12:34:56"
privacy_case "an IP address outside the documentation ranges" "node at 100.101.102.103"
privacy_case "an IP address outside the documentation ranges" "node at fd7a:115c:a1e0::1234"
privacy_case "a tailnet (*.ts.net) name" "reachable as laptop.tail1234.ts.net"
privacy_case "a UUID or device identifier" "disk 3f2504e0-4f89-11d3-9a0c-0305e82c3301"
privacy_case "a serial-number field" "Serial Number: ABC123XYZ"
privacy_case "a home-directory path naming an account" "state at /home/kasper/.config"
privacy_case "a home-directory path naming an account" "state at /Users/kasper/Library"
printf 'PASS: every personal-data shape fails, and the report never repeats the match\n'

# The version-row exemption is narrow: the same kernel string anywhere else is
# indistinguishable from an address, and is refused.
privacy_case "an IP address outside the documentation ranges" "kernel 6.6.87.2 seen"
printf 'PASS: an address-shaped version outside a version row is refused\n'

# --- Checklists keep their own shape ---------------------------------------

new_tree
replace_in "$acceptance/demo.md" "- **Pass when:** it works." ""
validate
assert_failure
assert_contains "$TEST_OUTPUT" "item DEM-02 is missing **Pass when:**"
printf 'PASS: a checklist item without a pass criterion fails\n'

new_tree
replace_in "$acceptance/demo.md" "### DEM-02 Second boundary" "### Second boundary"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "item heading must start with an ID"
printf 'PASS: a checklist item without an ID fails\n'

new_tree
replace_in "$acceptance/demo.md" "| DEM-02 | | |" ""
validate
assert_failure
assert_contains "$TEST_OUTPUT" "must list exactly the items"
printf 'PASS: a checklist results table that drops an item fails\n'

new_tree
replace_in "$acceptance/demo.md" "| DEM-02 | | |" "| DEM-02 | pass | |"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "outcome and notes must stay blank"
printf 'PASS: a checklist results table with a prefilled outcome fails\n'

new_tree
write_checklist "$acceptance/other.md"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "item prefix DEM is also used by"
printf 'PASS: two checklists sharing an item prefix fail\n'

new_tree
printf '# Not a checklist\n\nProse only.\n' >"$acceptance/notes.md"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "checklist has no '## Items' section"
printf 'PASS: a document in the checklist directory that is not a checklist fails\n'
