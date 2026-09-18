#!/usr/bin/env bash
# One TSV reader for every registry, and the arity it now enforces (RA-34).
#
# `scripts/lib/manifests.py` owns the quoting decision and the per-row column
# count for every `config/*.tsv`. Two things are proved here. First, that a row
# with one column too many or one too few is a schema error from whichever
# validator owns that registry, rather than a value that reaches a field check
# unexplained -- an extra trailing column used to be accepted silently. Second,
# that the Python reader and the `awk -F '\t'` the shell libraries read the same
# files with agree on where the fields are, including for a value that begins
# with a double quote, which `config/actions.tsv` genuinely contains.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# mutate <source> <target> <mode>: the registry, copied, with its last data row
# replaced by one carrying an extra or a missing trailing field. Every other row
# is untouched, so the copy differs from the passing state in exactly one way.
mutate() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import pathlib
import sys

source, target, mode = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3])
lines = source.read_text(encoding="utf-8").splitlines()
fields = lines[-1].split("\t")
if mode == "extra":
    fields.append("surplus")
else:
    fields.pop()
lines[-1] = "\t".join(fields)
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYTHON
}

# arity_case <label> <registry> <validator> <env-name>: both mutations of one
# registry, each asserted to fail with a schema error naming the offending line.
arity_case() {
  local label="$1" registry="$2" validator="$3" variable="$4"
  local mode copy
  for mode in extra missing; do
    copy="$root/$label-$mode.tsv"
    mutate "$repo_root/config/$registry" "$copy" "$mode"
    run_capture env "$variable=$copy" python3 "$repo_root/scripts/$validator"
    assert_failure
    assert_contains "$TEST_OUTPUT" 'line '
    if [[ "$mode" == extra ]]; then
      assert_contains "$TEST_OUTPUT" 'past the last column'
    else
      assert_contains "$TEST_OUTPUT" 'are missing'
    fi
    printf 'PASS: %s rejects a row with one %s column\n' "$registry" \
      "$([[ "$mode" == extra ]] && printf 'surplus' || printf 'absent')"
  done
}

# --- Every registry with an environment override ----------------------------

arity_case capabilities capabilities.tsv validate-capabilities.py CAPABILITY_MANIFEST
arity_case options install-options.tsv validate-install-options.py INSTALL_OPTION_MANIFEST
arity_case sources network-sources.tsv validate-network-sources.py NETWORK_SOURCE_MANIFEST
arity_case floors tool-floors.tsv validate-tool-floors.py TOOL_FLOOR_MANIFEST
arity_case commands command-providers.tsv validate-command-provider-closure.py \
  COMMAND_PROVIDER_MANIFEST

# --- The two registries addressed by --root instead --------------------------

# `validate-actions.py` and `validate-shell-file-roles.py` take a tree rather
# than a manifest path, so the mutation happens inside a copy of the tree. Both
# read far more than their own registry, which is why the copy is of the whole
# checkout rather than of `config/` alone.
scratch="$root/tree"
mkdir -p "$scratch"
tar -C "$repo_root" --exclude=.git -cf - . | tar -C "$scratch" -xf -

for mode in extra missing; do
  mutate "$repo_root/config/actions.tsv" "$scratch/config/actions.tsv" "$mode"
  run_capture python3 "$repo_root/scripts/validate-actions.py" --root "$scratch"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'action registry: line '
  printf 'PASS: actions.tsv rejects a row with one %s column\n' \
    "$([[ "$mode" == extra ]] && printf 'surplus' || printf 'absent')"
done
cp "$repo_root/config/actions.tsv" "$scratch/config/actions.tsv"

for mode in extra missing; do
  mutate "$repo_root/config/shell-file-roles.tsv" \
    "$scratch/config/shell-file-roles.tsv" "$mode"
  run_capture python3 "$repo_root/scripts/validate-shell-file-roles.py" \
    --root "$scratch"
  assert_failure
  assert_contains "$TEST_OUTPUT" 'shell-file roles: line '
  printf 'PASS: shell-file-roles.tsv rejects a row with one %s column\n' \
    "$([[ "$mode" == extra ]] && printf 'surplus' || printf 'absent')"
done
cp "$repo_root/config/shell-file-roles.tsv" "$scratch/config/shell-file-roles.tsv"

# --- The reader and awk read the same bytes the same way ---------------------

# A value that starts with a double quote and contains a tab is the case the
# three historical parsing behaviours disagreed about: the default dialect
# swallowed the tab into one field, `QUOTE_NONE` and `awk -F '\t'` did not.
quoted="$root/quoted.tsv"
printf 'id\tplatform\tvalue\ttrailing\n' >"$quoted"
printf 'one\tfedora\t"on-click": "swaymsg input\tnext"\n' >>"$quoted"

python_fields="$(python3 - "$quoted" <<'PYTHON'
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[0]).resolve().parent))
sys.path.insert(0, "scripts/lib")
from manifests import read_tsv  # noqa: E402

print(len(read_tsv(pathlib.Path(sys.argv[1]))[0]))
PYTHON
)"
awk_fields="$(awk -F '\t' 'NR == 2 { print NF }' "$quoted")"
assert_eq "$awk_fields" "$python_fields" \
  'the shared reader and awk -F "\t" agree on the field count of a quoted value'
assert_eq 4 "$python_fields" 'a leading double quote does not merge two fields'
printf 'PASS: a value beginning with a double quote parses identically in Python and awk\n'

# Every tracked registry, read both ways, agrees row for row. This is the check
# that would have caught the divergence before it mattered, rather than after a
# validator and an installer had disagreed about a live row.
skipped=()
for registry in "$repo_root"/config/*.tsv; do
  name="$(basename "$registry")"
  # A registry read through `read_tsv` opens with its header row. A `.tsv` under
  # `config/` that opens with a comment is a plain data file read by shell alone,
  # and the list of them is asserted below rather than filtered silently, so a
  # new one has to be classified deliberately instead of dropping out of here.
  if [[ "$(head -n 1 "$registry")" == \#* ]]; then
    skipped+=("$name")
    continue
  fi
  columns="$(awk -F '\t' 'NR == 1 { print NF }' "$registry")"
  mismatched="$(awk -F '\t' -v want="$columns" 'NF != want { print NR }' "$registry")"
  assert_eq "" "$mismatched" "awk reads every row of $name as $columns fields"
  python_rows="$(python3 - "$registry" <<'PYTHON'
import pathlib
import sys

sys.path.insert(0, "scripts/lib")
from manifests import read_tsv  # noqa: E402

print(len(read_tsv(pathlib.Path(sys.argv[1]))))
PYTHON
)"
  awk_rows="$(awk 'END { print NR - 1 }' "$registry")"
  assert_eq "$awk_rows" "$python_rows" "the shared reader and awk agree on $name"
done
assert_eq "terra-keys.tsv" "${skipped[*]}" \
  'the only comment-headed config/*.tsv is the Terra signing-key list'
printf 'PASS: every tracked registry reads identically through both readers\n'

printf 'Registry schema and shared-reader tests passed.\n'
