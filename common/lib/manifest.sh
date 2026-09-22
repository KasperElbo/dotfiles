#!/usr/bin/env bash

# Name-addressed reads of the tab-separated manifests under config/.
#
# Columns are located by name in each manifest's own header row on every read,
# never by a position stated in shell. A column reorder therefore cannot make
# an installer read packages or flags out of the wrong column, and a header
# that lacks, or repeats, a column the caller names fails loudly instead of
# answering from whatever happens to sit at that position. The Python
# validators pin the exact column order separately.
#
# Every data row is held to the header's column count, the way
# scripts/lib/manifests.py holds it. The two readers used to disagree about a
# short row: Python refused it and this one answered an empty value, so a
# truncated `packages` column read as "this capability installs nothing" and
# the installer finished green. Python runs in CI; this file is what runs on
# a user's machine during ./install.sh and platforms/*/scripts/verify.sh, where
# no validator ever runs, so it is the reader that most needed the rule.

# manifest_values <manifest> <fields> [<column> <value>]...
#
# Print, for every data row whose named key columns equal the given values,
# the comma-separated <fields> joined by tabs, in manifest order. No matching
# row is not an error. Exit 2 when the manifest is empty or its header is
# unusable for this query.
manifest_values() {
  _manifest_query all "$@"
}

# manifest_field <manifest> <fields> [<column> <value>]...
#
# Like manifest_values, but print only the first matching row, and exit 1
# when no row matches.
manifest_field() {
  _manifest_query first "$@"
}

_manifest_query() {
  local mode="$1" manifest="$2" fields="$3" keys="" separator=""
  shift 3
  (($# % 2 == 0)) || {
    printf 'Manifest query for %s names a key column without a value.\n' "$manifest" >&2
    return 2
  }
  while (($#)); do
    keys+="$separator$1"$'\t'"$2"
    separator=$'\t'
    shift 2
  done
  # Values travel through the environment rather than awk -v, which would
  # interpret backslash escapes in them.
  MANIFEST_PATH="$manifest" MANIFEST_MODE="$mode" MANIFEST_FIELDS="$fields" MANIFEST_KEYS="$keys" awk '
    function fail(message) {
      printf "Manifest %s %s\n", ENVIRON["MANIFEST_PATH"], message > "/dev/stderr"
      status = 2
      exit
    }
    BEGIN {
      FS = "\t"
      mode = ENVIRON["MANIFEST_MODE"]
      field_count = split(ENVIRON["MANIFEST_FIELDS"], fields, ",")
      key_count = split(ENVIRON["MANIFEST_KEYS"], keys, "\t")
    }
    NR == 1 {
      header_count = NF
      for (i = 1; i <= NF; i++) {
        if ($i in column) fail("repeats column: " $i)
        column[$i] = i
        name[i] = $i
      }
      for (i = 1; i <= field_count; i++)
        if (!(fields[i] in column)) fail("has no column: " fields[i])
      for (i = 1; i < key_count; i += 2)
        if (!(keys[i] in column)) fail("has no column: " keys[i])
      next
    }
    # Arity before the key comparison, not after: a short row whose key columns
    # happen to match would otherwise answer an empty value for a column it
    # does not have, which is the whole defect.
    NF != header_count {
      if (NF < header_count) {
        missing = ""
        for (i = NF + 1; i <= header_count; i++)
          missing = missing (missing ? ", " : "") name[i]
        fail(sprintf("line %d: columns %s are missing; a row must carry every one of the %d columns",
          FNR, missing, header_count))
      }
      surplus = ""
      for (i = header_count + 1; i <= NF; i++)
        surplus = surplus (surplus ? ", " : "") $i
      fail(sprintf("line %d: %d columns, expected %d: %s is past the last column",
        FNR, NF, header_count, surplus))
    }
    {
      for (i = 1; i < key_count; i += 2)
        if ($(column[keys[i]]) != keys[i + 1]) next
      line = ""
      for (i = 1; i <= field_count; i++)
        line = line (i > 1 ? "\t" : "") $(column[fields[i]])
      # "first" records its answer and keeps reading rather than exiting here,
      # so the arity rule above covers the whole manifest either way. A guard
      # that stops guarding once the caller has what it asked for would let a
      # malformed row below the first match through unseen.
      if (mode == "first") {
        if (!found) result = line
      } else {
        print line
      }
      found = 1
    }
    END {
      if (status) exit status
      if (NR == 0) {
        printf "Manifest %s is empty: it has no header row.\n", ENVIRON["MANIFEST_PATH"] > "/dev/stderr"
        exit 2
      }
      if (mode == "first") {
        if (!found) exit 1
        print result
      }
    }
  ' "$manifest"
}
