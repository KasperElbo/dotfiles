#!/usr/bin/env bash
# The gate that requires a verifier's checks to be able to fail.
#
# The audit's reproduction for GRADE-03 was a `check_*` call inserted into
# `platforms/fedora/scripts/verify.sh`: one file, no gate anywhere noticed it,
# and a predicate that can only ever pass is indistinguishable on the page from
# one that works. So the rule cannot be a parse. `common/lib/verify.sh` records
# which call site produced which verdict, and `scripts/validate-check-outcomes.py`
# reads that trace after the default suites have run.
#
# This suite drives the validator with traces it writes itself, because the
# thing under test is the rule, not the fixtures of every other suite. Each
# case is checked able to fail: a rule about checks that cannot fail must not
# be one.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

scratch_number=0

# A copy of the tree with a trace of its own, so a case can move a line, change
# an outcome or edit the ledger without touching the repository.
new_scratch() {
  scratch_number=$((scratch_number + 1))
  scratch="$root/scratch-$scratch_number"
  mkdir -p "$scratch"
  cp -R "$repo_root/." "$scratch/"
  rm -rf -- "$scratch/.git"
  trace="$root/trace-$scratch_number.tsv"
  : >"$trace"
}

# Give every call site in every verifier both outcomes, so a case's own edit is
# the only thing that can make the validator complain. The ledger is then all
# zeroes, which is the state the repository is working towards.
cover_everything() {
  python3 - "$scratch" "$trace" <<'PYTHON'
import pathlib
import re
import sys

scratch, trace = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
call = re.compile(r"^\s*(?:(?:if|while|until)\s+)?(?:!\s+)?check_[a-z0-9_]+\b")
lines = []
for pattern in ("platforms/*/scripts/verify*.sh", "common/verify-*.sh"):
    for path in scratch.glob(pattern):
        for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not text.lstrip().startswith("#") and call.match(text):
                lines.append(f"{path}\t{number}\tpass")
                lines.append(f"{path}\t{number}\tfail")
trace.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
  python3 "$scratch/scripts/validate-check-outcomes.py" --record "$trace" >/dev/null
}

validate() {
  run_capture python3 "$scratch/scripts/validate-check-outcomes.py" "$trace"
}

# The fully covered tree is the control every case below is measured against.
# Without it a case could pass because the tree was already red.
new_scratch
cover_everything
validate
assert_success
assert_contains "$TEST_OUTPUT" "156 check_* call sites"
printf 'PASS: a tree whose every check was driven both ways is accepted\n'

# GRADE-03's second acceptance criterion: a brand-new check with no fixture
# behind it is refused, and the message names where it is. The check goes in
# before the coverage is recorded, so the ledger says the tree was clean and
# the only uncovered site is the one this case added.
new_scratch
verifier="$scratch/platforms/fedora/scripts/verify.sh"
added_line="$(python3 - "$verifier" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
anchor = next(index for index, line in enumerate(lines) if line.startswith("section "))
lines.insert(
    anchor + 1,
    "  check_file_contains /etc/systemd/journald.conf 'Storage=persistent' "
    "'journald keeps logs across reboots'",
)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(anchor + 2)
PYTHON
)"
cover_everything
grep -v "^$verifier	$added_line	" "$trace" >"$trace.trimmed"
mv "$trace.trimmed" "$trace"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/verify.sh: 1 check_* call site "
assert_contains "$TEST_OUTPUT" "never driven to both a pass and a fail"
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/verify.sh:$added_line"
printf 'PASS: a new check no fixture can fail is refused, and located\n'

# GRADE-03's first acceptance criterion: a predicate that can no longer fail --
# an inverted condition, a needle that is always present -- loses its fail and
# is refused. The call site is unchanged; only what it produced is.
new_scratch
cover_everything
python3 - "$trace" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
kept, dropped = [], None
for line in path.read_text(encoding="utf-8").splitlines():
    location, _, outcome = line.rpartition("\t")
    if outcome == "fail" and "platforms/macos/scripts/verify.sh" in location and dropped is None:
        dropped = location
        continue
    kept.append(line)
if dropped is None:
    sys.exit("no macOS fail outcome to drop, so this case proves nothing")
path.write_text("\n".join(kept) + "\n", encoding="utf-8")
PYTHON
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/macos/scripts/verify.sh: 1 check_* call site "
printf 'PASS: a check that can no longer fail is refused\n'

# The ratchet only turns one way: coverage that was gained has to be recorded,
# or the next uncovered check would slip in under the old allowance.
new_scratch
cover_everything
python3 - "$scratch" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "config/check-outcomes.tsv"
lines = path.read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    if line.startswith("platforms/fedora/scripts/verify.sh\t"):
        verifier, _, note = line.split("\t")
        lines[index] = f"{verifier}\t3\t{note}"
        break
else:
    sys.exit("the Fedora verifier is not in the ledger, so this case proves nothing")
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
validate
assert_failure
assert_contains "$TEST_OUTPUT" "lower it to 0"
printf 'PASS: an allowance larger than the real gap is refused\n'

# A verifier the ledger does not mention is not silently exempt.
new_scratch
cover_everything
grep -v '^platforms/parrot-ctf/scripts/verify\.sh' \
  "$scratch/config/check-outcomes.tsv" >"$scratch/config/check-outcomes.tsv.new"
mv "$scratch/config/check-outcomes.tsv.new" "$scratch/config/check-outcomes.tsv"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "every verifier answers to this rule"
printf 'PASS: a verifier missing from the ledger is refused\n'

# The two ways this rule could pass for want of evidence. A gate that reports
# nothing when it learned nothing is the failure mode the verify tier keeps
# landing in, so both are errors rather than silence.
new_scratch
cover_everything
: >"$trace"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "names no call site in any verifier"
printf 'PASS: an empty trace is an error, not a pass\n'

new_scratch
cover_everything
rm -f "$trace"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "does not exist"
printf 'PASS: a missing trace is an error, not a pass\n'

# A suite that copies the tree and mutates the copy is proving something about
# the mutation. Its verdicts must not make the real call site look covered, or
# a check could be "covered" by a fixture that had edited it first.
new_scratch
cover_everything
sed "s|^$scratch/|/tmp/some-suite-scratch/|" "$trace" >"$trace.elsewhere"
mv "$trace.elsewhere" "$trace"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "names no call site in any verifier"
printf 'PASS: verdicts from a copy of the tree do not count as coverage\n'

printf 'Check-outcome gate tests passed.\n'
