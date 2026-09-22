#!/usr/bin/env bash

# Reading the network-source registry at install time.
#
# config/network-sources.tsv inventories every host this repository downloads
# from, and names the files that download from each. scripts/validate-network-
# sources.py already makes that inventory complete: a tracked file cannot
# introduce a fetch without annotating a registered source. So the registry is
# the authoritative answer to "what will this run ask of the network", and the
# preflight derives its probe set from it rather than from four hand-written
# lists that drift.
#
# Only the host is taken from a URL. A row's url may carry a placeholder that
# is only resolvable mid-run -- $releasever, ${fedora_version} -- and a
# connect-level probe of the host answers the question either way.
#
# It needs DOTFILES_ROOT from lib/common.sh, and sources that itself, so it is
# correct sourced standalone.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

NETWORK_SOURCE_MANIFEST="${NETWORK_SOURCE_MANIFEST:-$DOTFILES_ROOT/config/network-sources.tsv}"

# network_sources_hosts: read repository script paths on stdin, one per line,
# and print one "host<TAB>components" line per distinct host those scripts
# download from. Hosts are printed in first-seen registry order so a run's
# diagnostics are stable.
#
# Only https sources take part: fetch_host_reachable probes with
# `--proto '=https'`, and the container-image rows carry a registry reference
# rather than a URL.
network_sources_hosts() {
  local manifest="${1:-$NETWORK_SOURCE_MANIFEST}"

  [[ -r "$manifest" ]] || {
    printf 'Network-source registry is missing or unreadable: %s\n' "$manifest" >&2
    return 1
  }

  # Which of the two inputs a record came from is decided by an ARGV
  # assignment between them, not by `NR == FNR`. That idiom means "still on
  # the first file", which is only the same thing while the first file has
  # records: with nothing on stdin the manifest became the first file, every
  # one of its rows was swallowed into the wanted-set, and the header check
  # below never ran. A registry with no url, component or consumers column
  # then reported success, and it did so in exactly the case that matters --
  # a plan with no networked step contributes no scripts, so the offline run
  # is the one where the schema went unchecked. `pass=rows` is evaluated when
  # awk reaches it in ARGV, after stdin is exhausted and before the manifest
  # is opened, whether or not stdin held anything.
  awk -F'\t' -v manifest="$manifest" -v pass=wanted '
    pass == "wanted" {
      if ($0 != "") wanted[$0] = 1
      next
    }
    FNR == 1 {
      header_seen = 1
      for (column = 1; column <= NF; column++) index_of[$column] = column
      if (!("url" in index_of) || !("consumers" in index_of) || !("component" in index_of)) {
        print "network-source registry has no url, component or consumers column: " manifest > "/dev/stderr"
        failed = 1
        exit 1
      }
      next
    }
    {
      url = $index_of["url"]
      if (url !~ /^https:\/\//) next

      count = split($index_of["consumers"], consumers, ",")
      matched = 0
      for (i = 1; i <= count; i++) if (consumers[i] in wanted) matched = 1
      if (!matched) next

      host = url
      sub(/^https:\/\//, "", host)
      sub(/\/.*$/, "", host)
      if (host == "") next

      if (!(host in components)) {
        order[++hosts] = host
        components[host] = $index_of["component"]
      } else if (index(components[host], $index_of["component"]) == 0) {
        components[host] = components[host] ", " $index_of["component"]
      }
    }
    END {
      if (failed) exit 1
      # The mirror image of the case above: a rule that never fires checks
      # nothing. An empty registry has no first record, so the header rule
      # never runs, and `[[ -r ]]` is satisfied by a zero-byte file -- so a
      # truncated or half-written registry printed no hosts and returned 0,
      # which is exactly what "this plan asks nothing of the network" looks
      # like. The two have to be distinguishable, and only one of them is a
      # reason to carry on.
      if (!header_seen) {
        print "network-source registry has no header row: " manifest > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= hosts; i++) printf "%s\t%s\n", order[i], components[order[i]]
    }
  ' - pass=rows "$manifest"
}
