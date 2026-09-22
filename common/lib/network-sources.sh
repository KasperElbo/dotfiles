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

  awk -F'\t' -v manifest="$manifest" '
    # Which file a record came from is decided by name, not by NR == FNR. That
    # idiom reads "still in the first file", but it is really "no record has
    # been read twice yet", and with an empty first file it stays true for the
    # whole second one. The schema check below would then never run, and a
    # registry missing a column it needs would be accepted silently -- for any
    # plan that happens to contribute no scripts, which is the one case where
    # nothing else would notice either.
    FILENAME != manifest {
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
      # Readable and empty is still a registry that cannot be read. Without
      # this the header rule never fires and the run probes nothing, which
      # looks exactly like a plan that asks nothing of the network.
      if (!header_seen) {
        print "network-source registry is empty: it has no header row: " manifest > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= hosts; i++) printf "%s\t%s\n", order[i], components[order[i]]
    }
  ' - "$manifest"
}
