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
# the only thing that can make the validator complain.
trace_everything() {
  python3 - "$scratch" "$trace" <<'PYTHON'
import pathlib
import re
import sys

scratch, trace = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
call = re.compile(r"^\s*(?:(?:if|while|until)\s+)?(?:!\s+)?check_[a-z0-9_]+\b(?!\s*\(\))")
lines = []
for pattern in ("platforms/*/scripts/verify*.sh", "common/verify-*.sh"):
    for path in scratch.glob(pattern):
        for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not text.lstrip().startswith("#") and call.match(text):
                lines.append(f"{path}\t{number}\tpass")
                lines.append(f"{path}\t{number}\tfail")
trace.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
}

# The same, with the ledger recorded from it, so it excuses nothing: the state
# the repository is working towards.
cover_everything() {
  trace_everything
  python3 "$scratch/scripts/validate-check-outcomes.py" --record "$trace" >/dev/null
}

# The line of a verifier's Nth traced call site, counting from 1, or from the
# end when negative.
site_line() {
  python3 - "$trace" "$scratch/$1" "$2" <<'PYTHON'
import sys

trace, verifier, which = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(trace, encoding="utf-8") as lines:
    sites = sorted({int(line.split("\t")[1]) for line in lines if line.startswith(verifier + "\t")})
if len(sites) < 2:
    sys.exit(f"fewer than two call sites traced in {verifier}, so this case proves nothing")
print(sites[which - 1 if which > 0 else which])
PYTHON
}

# Take one outcome away from one call site, as a fixture that stopped driving
# it that way would.
drop_outcome() {
  grep -v -x -F "$scratch/$1	$2	$3" "$trace" >"$trace.dropped" || true
  if cmp -s "$trace" "$trace.dropped"; then
    _test_die "no $3 traced at $1:$2, so this case proves nothing"
  fi
  mv "$trace.dropped" "$trace"
}

# Record the ledger from the trace as it stands, and give every row a reason,
# as a contributor excusing those call sites would have to.
excuse_uncovered() {
  python3 "$scratch/scripts/validate-check-outcomes.py" --record "$trace" >/dev/null
  python3 - "$scratch/config/check-outcomes.tsv" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rows = path.read_text(encoding="utf-8").splitlines()
rows[1:] = [row if row.split("\t")[2] else row + "excused by this case" for row in rows[1:]]
path.write_text("\n".join(rows) + "\n", encoding="utf-8")
PYTHON
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
# Covered and total have to agree; the total itself is whatever the tree
# holds, so adding a verifier check does not break the control.
[[ "$TEST_OUTPUT" =~ coverage:\ ([0-9]+)\ of\ ([0-9]+)\ check_\*\ call\ sites ]] &&
  ((BASH_REMATCH[1] == BASH_REMATCH[2] && BASH_REMATCH[2] > 0)) ||
  _test_die "the fully covered tree did not report every call site covered:\n$TEST_OUTPUT"
printf 'PASS: a tree whose every check was driven both ways is accepted\n'

# GRADE-03's second acceptance criterion: a brand-new check with no fixture
# behind it is refused, and the message names where it is and which call it
# is. The check goes in before the coverage is recorded, so the ledger says the
# tree was clean and the only uncovered site is the one this case added.
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
drop_outcome platforms/fedora/scripts/verify.sh "$added_line" pass
drop_outcome platforms/fedora/scripts/verify.sh "$added_line" fail
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/verify.sh:$added_line: \`check_file_contains /etc/systemd/journald.conf 'Storage=persistent' 'journald keeps logs across reboots'\`"
assert_contains "$TEST_OUTPUT" "never driven to both a pass and a fail"
printf 'PASS: a new check no fixture can fail is refused, and named\n'

# A verifier that is new to the tree answers to the same rule. There is no
# per-verifier row to forget: every call site the ledger does not excuse is
# refused wherever it is.
new_scratch
cover_everything
new_verifier="verify-$scratch_number.sh"
printf '#!/usr/bin/env bash\ncheck_command dotfiles-new-verifier-tool\n' \
  >"$scratch/platforms/fedora/scripts/$new_verifier"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/$new_verifier:2: \`check_command dotfiles-new-verifier-tool\`"
printf 'PASS: a new verifier is not exempt\n'

# GRADE-03's first acceptance criterion: a predicate that can no longer fail --
# an inverted condition, a needle that is always present -- loses its fail and
# is refused. The call site is unchanged; only what it produced is.
new_scratch
cover_everything
lost_line="$(site_line platforms/macos/scripts/verify.sh 1)"
drop_outcome platforms/macos/scripts/verify.sh "$lost_line" fail
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/macos/scripts/verify.sh:$lost_line: \`check_"
assert_contains "$TEST_OUTPUT" "does not excuse it"
printf 'PASS: a check that can no longer fail is refused\n'

# An exception belongs to one call site, not to its verifier's total (#497).
# Excuse one macOS site, then cover it and uncover another: the count is the
# same, but the check that lost its failing fixture is not the one the ledger
# excused, so it is refused and named.
new_scratch
cover_everything
excused_line="$(site_line platforms/macos/scripts/verify.sh 1)"
lost_line="$(site_line platforms/macos/scripts/verify.sh -1)"
cp "$trace" "$trace.full"
drop_outcome platforms/macos/scripts/verify.sh "$excused_line" fail
excuse_uncovered
validate
assert_success
cp "$trace.full" "$trace"
drop_outcome platforms/macos/scripts/verify.sh "$lost_line" fail
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/macos/scripts/verify.sh:$lost_line: \`check_"
printf 'PASS: swapping which check is uncovered, at the same count, is refused\n'

# An exception follows its call when unrelated lines move it. Excuse the
# second macOS call site, then add lines above the first until the first call
# sits on the line the excused one used to: a ledger keyed by line would now
# excuse the wrong check. The excused call, wherever it went, stays excused;
# the call that took its old line does not inherit that.
new_scratch
cover_everything
first_line="$(site_line platforms/macos/scripts/verify.sh 1)"
excused_line="$(site_line platforms/macos/scripts/verify.sh 2)"
drop_outcome platforms/macos/scripts/verify.sh "$excused_line" fail
excuse_uncovered
shift_by=$((excused_line - first_line))
python3 - "$scratch/platforms/macos/scripts/verify.sh" "$first_line" "$shift_by" <<'PYTHON'
import pathlib
import sys

path, before, count = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
lines = path.read_text(encoding="utf-8").splitlines()
lines[before - 1:before - 1] = ["# moved by an unrelated change"] * count
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
trace_everything
drop_outcome platforms/macos/scripts/verify.sh "$((excused_line + shift_by))" fail
validate
assert_success
trace_everything
drop_outcome platforms/macos/scripts/verify.sh "$excused_line" fail
validate
assert_failure
assert_contains "$TEST_OUTPUT" "platforms/macos/scripts/verify.sh:$excused_line: \`check_"
printf 'PASS: an exception follows its call when unrelated lines move it\n'

# A call made twice in one verifier is told apart by its occurrence, so one of
# them can be excused without excusing the other.
new_scratch
cover_everything
mapfile -t twin_lines < <(grep -n '^[[:space:]]*check_private_key_mode "\$key"$' \
  "$scratch/platforms/fedora/scripts/verify-hardening.sh" | cut -d: -f1)
((${#twin_lines[@]} == 2)) ||
  _test_die "expected the hardening verifier's two identical key-mode calls, found ${#twin_lines[@]}"
cp "$trace" "$trace.full"
drop_outcome platforms/fedora/scripts/verify-hardening.sh "${twin_lines[1]}" fail
excuse_uncovered
assert_contains "$(cat "$scratch/config/check-outcomes.tsv")" 'check_private_key_mode "$key" (occurrence 2)'
validate
assert_success
cp "$trace.full" "$trace"
drop_outcome platforms/fedora/scripts/verify-hardening.sh "${twin_lines[0]}" fail
validate
assert_failure
assert_contains "$TEST_OUTPUT" "verify-hardening.sh:${twin_lines[0]}: \`check_private_key_mode \"\$key\"\`"
printf 'PASS: two identical calls are excused one at a time\n'

# A real gain is reported, not refused, with what to do about it. Coverage is
# measured behaviour: a machine with podman or systemctl drives checks to a
# verdict that a machine without them reports as not observed, so the rows are
# the worst environment's and a better one covers some of them.
new_scratch
cover_everything
gained_line="$(site_line platforms/fedora/scripts/verify.sh 1)"
cp "$trace" "$trace.full"
drop_outcome platforms/fedora/scripts/verify.sh "$gained_line" fail
excuse_uncovered
cp "$trace.full" "$trace"
validate
assert_success
assert_contains "$TEST_OUTPUT" "platforms/fedora/scripts/verify.sh:$gained_line: \`check_"
assert_contains "$TEST_OUTPUT" "still excuses it; delete its row, or re-record with --record"
printf 'PASS: a check the ledger excuses that is now covered is reported, not refused\n'

# Every exception says why. A row --record wrote for a newly uncovered site
# has no reason until someone writes one, and until then it excuses nothing.
new_scratch
cover_everything
reasonless_line="$(site_line platforms/fedora/scripts/verify.sh 1)"
drop_outcome platforms/fedora/scripts/verify.sh "$reasonless_line" fail
run_capture python3 "$scratch/scripts/validate-check-outcomes.py" --record "$trace"
assert_success
assert_contains "$TEST_OUTPUT" "1 of them have no reason yet"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "has no reason"
printf 'PASS: an exception without a reason is refused\n'

# A row naming a call the verifier no longer makes is refused, so an exception
# cannot outlive its check and quietly excuse whatever is written that way next.
new_scratch
cover_everything
printf 'platforms/fedora/scripts/verify.sh\tcheck_command dotfiles-long-gone\ta removed check\n' \
  >>"$scratch/config/check-outcomes.tsv"
validate
assert_failure
assert_contains "$TEST_OUTPUT" "excuses \`check_command dotfiles-long-gone\` in platforms/fedora/scripts/verify.sh, which makes no such call"
printf 'PASS: an exception for a call that no longer exists is refused\n'

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

# A call whose first argument starts on the next line is credited by bash to
# that next line, so the trace never names the line this gate counts. Three
# Fedora symlink checks sat uncovered that way while their suites drove them
# both ways. The case credits the split line itself, so only the refusal can
# turn it red.
new_scratch
verifier="$scratch/platforms/fedora/scripts/verify.sh"
python3 - "$verifier" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
anchor = next(index for index, line in enumerate(lines) if line.startswith("section "))
lines[anchor + 1:anchor + 1] = [
    "  check_file_contains \\",
    "    /etc/systemd/journald.conf 'Storage=persistent' 'journald keeps logs'",
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
cover_everything
validate
assert_failure
assert_contains "$TEST_OUTPUT" "the call's first argument is on the next line"
printf 'PASS: a call split before its first argument is refused\n'

# A verifier's own check_* helper credits the line that called it. The trace
# used to stop at the first frame outside the library, which for such a helper
# is its own pass or fail line, so the call site the rule counts was never
# credited however often a suite drove it: the hardening verifier's drop-in,
# sysctl and key-mode checks all read as never driven. The verifier here runs
# in its own bash process, as a real one does, and the nested case keeps the
# library helper's own line credited too, since that is a call site as well.
local_verifier="$root/local-helper-verify.sh"
cat >"$local_verifier" <<SHELL
#!/usr/bin/env bash
set -u
source "$repo_root/common/lib/verify.sh"
check_local() {
  if [[ "\$1" == yes ]]; then
    pass "local helper passed"
  else
    fail "local helper failed"
  fi
}
check_outer() {
  check_command dotfiles-no-such-command-for-this-case
}
check_local yes
check_local no
check_outer
exit 0
SHELL
local_trace="$root/local-helper-trace.tsv"
: >"$local_trace"
run_capture env DOTFILES_VERIFY_TRACE="$local_trace" bash "$local_verifier"
assert_success
local_recorded="$(cat "$local_trace")"
[[ -n "$local_recorded" ]] ||
  _test_die "the local-helper verifier traced nothing, so this case proves nothing"
assert_contains "$local_recorded" "$local_verifier	14	pass"
assert_contains "$local_recorded" "$local_verifier	15	fail"
assert_contains "$local_recorded" "$local_verifier	12	fail"
assert_contains "$local_recorded" "$local_verifier	16	fail"
printf 'PASS: a check_* helper defined in a verifier credits the line that called it\n'

printf 'Check-outcome gate tests passed.\n'
