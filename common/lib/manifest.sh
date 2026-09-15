#!/usr/bin/env bash

# Name-addressed reads of the tab-separated manifests under config/.
#
# Columns are located by name in each manifest's own header row on every read,
# never by a position stated in shell. A column reorder therefore cannot make
# an installer read packages or flags out of the wrong column, and a header
# that lacks, or repeats, a column the caller names fails loudly instead of
# answering from whatever happens to sit at that position. The Python
# validators pin the exact column order separately.

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
      for (i = 1; i <= NF; i++) {
        if ($i in column) fail("repeats column: " $i)
        column[$i] = i
      }
      for (i = 1; i <= field_count; i++)
        if (!(fields[i] in column)) fail("has no column: " fields[i])
      for (i = 1; i < key_count; i += 2)
        if (!(keys[i] in column)) fail("has no column: " keys[i])
      next
    }
    {
      for (i = 1; i < key_count; i += 2)
        if ($(column[keys[i]]) != keys[i + 1]) next
      line = ""
      for (i = 1; i <= field_count; i++)
        line = line (i > 1 ? "\t" : "") $(column[fields[i]])
      print line
      found = 1
      if (mode == "first") exit
    }
    END {
      if (status) exit status
      if (NR == 0) {
        printf "Manifest %s is empty: it has no header row.\n", ENVIRON["MANIFEST_PATH"] > "/dev/stderr"
        exit 2
      }
      if (mode == "first" && !found) exit 1
    }
  ' "$manifest"
}
