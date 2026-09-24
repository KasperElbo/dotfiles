#!/usr/bin/env bash

# A portable entry point, so it may be started under Apple's Bash 3.2: on macOS
# `env bash` resolves to /bin/bash whenever Homebrew is not ahead of it on PATH.
# Everything down to the modern-Bash guard therefore stays inside that dialect,
# and `set -euo pipefail` waits until after it, as scripts/lint.sh does.

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"

# shellcheck source=../common/lib/modern-bash.sh
. "$repo_root/common/lib/modern-bash.sh"
modern_bash_reexec ./scripts/check-pin-freshness.sh "$script_path" "$@" || exit 2

set -euo pipefail
cd "$repo_root"

# Report which manual-bump pin has fallen behind its upstream.
#
# config/network-sources.tsv records a cadence for every source. Most are
# rolling: a package manager, a registry or a version line tells the machine
# itself that something moved. The `manual-bump` rows are the exception, and
# they were the strongest pins in the repository with the weakest notification:
# an exact tag or a SHA-256 that nothing on earth would ever mention again.
#
# The scheduled real-install validation catches a pin that has *broken* -- a
# download that 404s, a digest that no longer matches -- because it installs
# from them for real. It cannot catch a pin that is merely three releases old
# and still serving its bytes correctly, because nothing about that run is
# wrong. This report is the missing half: it asks each upstream what it has
# now, and prints that next to what this repository pins.
#
# It is a report. It downloads no artifact, writes no file, opens nothing and
# changes nothing; `git ls-remote` reads refs and transfers no objects. What to
# do about a pin that is behind stays a reviewed act, because reviewing the new
# release is the entire point of pinning it in the first place.
#
# Where the pinned value lives is config/pin-freshness.tsv's business, and it
# is read out of the installer that uses it rather than repeated here, so a
# bump cannot leave this report comparing against the previous release.
# scripts/validate-pin-freshness.py holds that manifest to the registry: a new
# manual-bump source cannot be added without saying how its staleness is
# noticed, which is the hole this whole mechanism exists to close.

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/manifest.sh
source "$repo_root/common/lib/manifest.sh"

PIN_FRESHNESS_MANIFEST="${PIN_FRESHNESS_MANIFEST:-$DOTFILES_ROOT/config/pin-freshness.tsv}"

fail_on_stale=false

usage() {
  cat <<'EOF_USAGE'
Usage: ./scripts/check-pin-freshness.sh [--fail-on-stale]

Print, for every manual-bump source in config/network-sources.tsv, the version
this repository pins and the newest one its upstream now offers.

Read-only: it downloads no artifact, writes no file and changes no pin.

Options:
  --fail-on-stale  Exit non-zero when a pin is behind its upstream. Without it,
                   a stale pin is reported and the run still succeeds.
  -h, --help       Show this help.

Exit status:
  0  every pin was read and probed, and none is behind (or one is, and
     --fail-on-stale was not given)
  1  a pin could not be read, an upstream could not be reached, or -- with
     --fail-on-stale -- a pin is behind
  2  usage error

A row whose probe is `none` is printed as "not probed" with the reason its
manifest row states. That is deliberate: a source this report cannot ask about
is visible in the output rather than quietly absent from it.
EOF_USAGE
}

while (($#)); do
  case "$1" in
  --fail-on-stale)
    fail_on_stale=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

# pin_value <file> <key>: the value of a `key="value"` assignment, which is the
# shape every pinned literal in this repository is written in -- or, in a
# PowerShell data file (.psd1), of a `Key = 'value'` entry, which is how the
# Windows manifest spells one. Exactly one
# match is required: no match means the pin moved or was renamed, and several
# mean the file states it twice, and both are reasons to stop rather than to
# report a comparison against a value that may not be the live one.
pin_value() {
  local file="$1" key="$2"
  local matches count

  [[ -r "$file" ]] || {
    printf 'cannot read the pin file: %s\n' "$file" >&2
    return 1
  }

  if [[ "$file" == *.psd1 ]]; then
    matches="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*'\\([^']*\\)'[[:space:]]*\$/\\1/p" "$file")" ||
      return 1
  else
    matches="$(sed -n "s/^${key}=\"\\([^\"]*\\)\"\$/\\1/p" "$file")" || return 1
  fi
  [[ -n "$matches" ]] || {
    printf 'no %s="..." assignment in %s\n' "$key" "$file" >&2
    return 1
  }
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  ((count == 1)) || {
    printf '%s assigns %s %s times; it must state its pin once\n' \
      "$file" "$key" "$count" >&2
    return 1
  }
  printf '%s\n' "$matches"
}

# comparable_version <value>: the dotted-numeric form of a release name, or
# nothing when it has none. A leading `v` is decoration, and a trailing build
# field written with a hyphen -- netcoredbg's 3.1.3-1062 -- orders like a
# further dotted field. Anything left with a non-numeric part (a release
# candidate, a date-stamped nightly) has no total order this can rely on, so it
# is reported as incomparable rather than ranked by a guess.
comparable_version() {
  local value="${1#v}"
  value="${value//-/.}"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
  printf '%s\n' "$value"
}

# newest_tag <url>: the highest comparable tag the remote publishes.
#
# Tags that are not comparable are skipped here rather than failing the probe:
# a repository that also tags nightlies or release candidates still has a
# newest release, and refusing to answer because of the others would make the
# report useless for exactly the upstreams it is most needed for. A repository
# with no comparable tag at all is a probe failure, because then there is
# nothing to compare and silence would read as "current".
newest_tag() {
  local url="$1"
  local refs line tag best="" best_version candidate

  # network-source: pin-freshness-probe
  refs="$(git ls-remote --tags --refs -- "$url" 2>&1)" || {
    printf '%s\n' "$refs" >&2
    return 1
  }

  best_version=""
  while IFS= read -r line; do
    tag="${line##*refs/tags/}"
    [[ -n "$tag" && "$tag" != "$line" ]] || continue
    candidate="$(comparable_version "$tag")" || continue
    if [[ -z "$best_version" ]] || version_at_least "$candidate" "$best_version"; then
      best_version="$candidate"
      best="$tag"
    fi
  done <<<"$refs"

  [[ -n "$best" ]] || {
    printf 'no comparable tag among the refs %s publishes\n' "$url" >&2
    return 1
  }
  printf '%s\n' "$best"
}

# head_commit <url>: the commit the remote's default branch points at, for a
# pin that names a commit rather than a release.
head_commit() {
  local url="$1"
  local output commit

  # network-source: pin-freshness-probe
  output="$(git ls-remote -- "$url" HEAD 2>&1)" || {
    printf '%s\n' "$output" >&2
    return 1
  }
  commit="${output%%$'\t'*}"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'could not read a HEAD commit from %s\n' "$url" >&2
    return 1
  }
  printf '%s\n' "$commit"
}

command_exists git || die "git is required to read upstream refs, and was not found on PATH"

rows="$(manifest_values "$PIN_FRESHNESS_MANIFEST" source,probe,target,pin_file,pin_key,note)" ||
  die "Could not read the pin freshness manifest: $PIN_FRESHNESS_MANIFEST"
[[ -n "$rows" ]] || die "The pin freshness manifest has no rows: $PIN_FRESHNESS_MANIFEST"

report=()
behind=0
errors=0
current=0
unprobed=0

while IFS=$'\t' read -r source probe target pin_file pin_key note; do
  [[ -n "$source" ]] || continue

  if [[ "$probe" == none ]]; then
    report+=("$source"$'\t'"-"$'\t'"-"$'\t'"not probed")
    unprobed=$((unprobed + 1))
    continue
  fi

  pinned=""
  if ! pinned="$(pin_value "$pin_file" "$pin_key")"; then
    report+=("$source"$'\t'"?"$'\t'"-"$'\t'"pin unreadable")
    errors=$((errors + 1))
    continue
  fi

  upstream=""
  case "$probe" in
  git-tags)
    upstream="$(newest_tag "$target")" || upstream=""
    ;;
  git-head)
    upstream="$(head_commit "$target")" || upstream=""
    ;;
  *)
    printf 'Unknown probe %s for %s\n' "$probe" "$source" >&2
    upstream=""
    ;;
  esac

  if [[ -z "$upstream" ]]; then
    report+=("$source"$'\t'"$pinned"$'\t'"?"$'\t'"probe failed")
    errors=$((errors + 1))
    continue
  fi

  case "$probe" in
  git-tags)
    pinned_version="$(comparable_version "$pinned")" || pinned_version=""
    upstream_version="$(comparable_version "$upstream")" || upstream_version=""
    if [[ -z "$pinned_version" || -z "$upstream_version" ]]; then
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"not comparable")
      errors=$((errors + 1))
    elif [[ "$pinned_version" == "$upstream_version" ]]; then
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"current")
      current=$((current + 1))
    elif version_at_least "$upstream_version" "$pinned_version"; then
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"BEHIND")
      behind=$((behind + 1))
    else
      # The pin is ahead of the newest tag the remote publishes, which happens
      # when a release is withdrawn. Worth a human's attention either way.
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"ahead of upstream")
      errors=$((errors + 1))
    fi
    ;;
  git-head)
    if [[ "$pinned" == "$upstream" ]]; then
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"current")
      current=$((current + 1))
    else
      report+=("$source"$'\t'"$pinned"$'\t'"$upstream"$'\t'"BEHIND")
      behind=$((behind + 1))
    fi
    ;;
  esac
done <<<"$rows"

printf 'Pinned components, and what their upstreams offer now\n\n'
{
  printf 'SOURCE\tPINNED\tUPSTREAM\tSTATE\n'
  printf '%s\n' "${report[@]}"
} | awk -F'\t' '
  {
    rows = NR
    columns = NF
    for (column = 1; column <= NF; column++) {
      cell[NR, column] = $column
      if (length($column) > width[column]) width[column] = length($column)
    }
  }
  END {
    for (row = 1; row <= rows; row++) {
      printf "  "
      for (column = 1; column < columns; column++)
        printf "%-*s  ", width[column], cell[row, column]
      printf "%s\n", cell[row, columns]
    }
  }
'

printf '\n'
printf '%d current, %d behind, %d not probed, %d could not be checked.\n' \
  "$current" "$behind" "$unprobed" "$errors"

if ((unprobed > 0)); then
  printf '\nNot probed, and why:\n'
  while IFS=$'\t' read -r source probe _ _ _ note; do
    [[ "$probe" == none ]] || continue
    printf '  %s: %s\n' "$source" "$note"
  done <<<"$rows"
fi

# A probed row may carry a note too, and when it does the note is usually the
# reason a row will keep reporting BEHIND: an upstream that stopped publishing
# the artifact this repository consumes still publishes releases. Printing it
# beside the table is what stops a standing, explained difference reading as an
# unexamined one every month.
notes=0
while IFS=$'\t' read -r _ probe _ _ _ note; do
  [[ "$probe" != none && "$note" != "-" ]] || continue
  notes=$((notes + 1))
done <<<"$rows"

if ((notes > 0)); then
  printf '\nNotes:\n'
  while IFS=$'\t' read -r source probe _ _ _ note; do
    [[ "$probe" != none && "$note" != "-" ]] || continue
    printf '  %s: %s\n' "$source" "$note"
  done <<<"$rows"
fi

if ((behind > 0)); then
  printf '\nA pin reported BEHIND is a prompt to go and look, not an instruction\n'
  printf 'to bump: a newer tag may be a pre-release, and adopting a release is a\n'
  printf 'reviewed act. docs/supply-chain.md says how each kind of pin is moved.\n'
fi

if ((errors > 0)); then
  exit 1
fi
if ((behind > 0)) && [[ "$fail_on_stale" == true ]]; then
  exit 1
fi
exit 0
