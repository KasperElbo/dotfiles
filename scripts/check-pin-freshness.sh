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
#
# --coherence asks a different question of the same rows: does the digest this
# repository pins belong to the thing it pins? A bump edits a version or a
# commit and its SHA-256 together, and nothing offline can tell a digest copied
# from the wrong release -- or a valid-looking 64-hex value from nowhere --
# from the right one; every installer that checks it would just refuse the
# download on a real machine, weeks later (#539, V5-27). So that mode fetches
# each pinned artifact from its pinned address into a private directory,
# compares its SHA-256 with the pin, and deletes it. It still changes nothing.

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/manifest.sh
source "$repo_root/common/lib/manifest.sh"

PIN_FRESHNESS_MANIFEST="${PIN_FRESHNESS_MANIFEST:-$DOTFILES_ROOT/config/pin-freshness.tsv}"

fail_on_stale=false
coherence=false
list_only=false

usage() {
  cat <<'EOF_USAGE'
Usage: ./scripts/check-pin-freshness.sh [--fail-on-stale]
       ./scripts/check-pin-freshness.sh --coherence [--list]

Print, for every manual-bump source in config/network-sources.tsv, the version
this repository pins and the newest one its upstream now offers.

Read-only: it downloads no artifact, writes no file and changes no pin.

Options:
  --fail-on-stale  Exit non-zero when a pin is behind its upstream. Without it,
                   a stale pin is reported and the run still succeeds.
  --coherence      Instead, download every artifact a row pins a SHA-256 for,
                   from its pinned address, and check that the digest belongs
                   to it. Each download goes to a private directory that is
                   removed afterwards; nothing else is written.
  --list           With --coherence, print each pinned address and digest
                   without downloading anything.
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
  --coherence)
    coherence=true
    shift
    ;;
  --list)
    list_only=true
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

# coherence_pairs <source> <pin_file> <pin_key>: one `url<TAB>digest` line for
# each artifact the row pins a SHA-256 for, or a single `-<TAB>reason` line when
# the row pins none. A source this has no answer for is an error, so a row added
# to config/pin-freshness.tsv is not silently left out of the check.
#
# Where the installer builds the address in a library, the library is sourced
# and asked, so this cannot drift from what a machine downloads. Where the
# address is written inline in a script, it is restated here from the pinned
# values; a restatement that drifted names an address the upstream does not
# serve, which fails the run rather than passing it. Each source is read in its
# own subshell: the libraries define functions of the same names, and their
# test seams are unset so only the pinned address can answer.
coherence_pairs() {
  local source="$1" pin_file="$2" pin_key="$3"
  local version digest key commit flavour

  case "$source" in
  homebrew-installer)
    (
      # shellcheck source=../platforms/macos/lib/homebrew-installer.sh
      source "$pin_file" || exit 1
      printf '%s\t%s\n' "$(homebrew_installer_url)" "$DOTFILES_HOMEBREW_INSTALLER_SHA256"
    )
    ;;
  mise-release | starship-release)
    (
      unset DOTFILES_TEST_BOOTSTRAP_ARCHIVES
      # shellcheck source=../common/lib/bootstrap-tools.sh
      source "$pin_file" || exit 1
      # Every architecture it pins, not only this runner's: the digest for the
      # other one is the easiest to get wrong and the last to be exercised.
      for coherence_machine in x86_64 aarch64; do
        # shellcheck disable=SC2329 # Called by bootstrap_tool_artifact.
        uname() { printf '%s\n' "$coherence_machine"; }
        IFS=$'\t' read -r artifact digest _ < <(bootstrap_tool_artifact "${source%-release}") ||
          exit 1
        printf '%s\t%s\n' "$(bootstrap_tool_url "${source%-release}" "$artifact")" "$digest"
      done
    )
    ;;
  ghost-pepper-release | handy-release)
    (
      unset DOTFILES_TEST_HANDY_RPM
      # shellcheck source=/dev/null # Either platform's dictation library.
      source "$pin_file" || exit 1
      if [[ "$source" == handy-release ]]; then
        digest="$(dictation_pinned_sha256)" || exit 1
      else
        digest="$DICTATION_GHOST_PEPPER_SHA256"
      fi
      printf '%s\t%s\n' "$(dictation_release_url)" "$digest"
    )
    ;;
  gitleaks-release)
    version="$(pin_value "$pin_file" "$pin_key")" || return 1
    for key in linux_x64 linux_arm64 darwin_x64 darwin_arm64; do
      digest="$(pin_value "$pin_file" "sha256_$key")" || return 1
      # Restated from scripts/scan-secrets.sh.
      printf 'https://github.com/gitleaks/gitleaks/releases/download/v%s/gitleaks_%s_%s.tar.gz\t%s\n' \
        "$version" "$version" "$key" "$digest"
    done
    ;;
  hack-nerd-font)
    version="$(pin_value "$pin_file" "$pin_key")" || return 1
    digest="$(pin_value "$pin_file" font_sha256)" || return 1
    # Restated from platforms/parrot-ctf/scripts/install-terminal.sh.
    printf 'https://github.com/ryanoasis/nerd-fonts/releases/download/v%s/Hack.tar.xz\t%s\n' \
      "$version" "$digest"
    ;;
  catppuccin-bat-themes)
    commit="$(pin_value "$pin_file" "$pin_key")" || return 1
    for flavour in Latte Frappe Macchiato Mocha; do
      digest="$(sed -n "s/^[[:space:]]*\\[${flavour}\\]=\"\\([0-9a-f]*\\)\"\$/\\1/p" "$pin_file")"
      [[ -n "$digest" ]] || {
        printf 'no pinned digest for the %s bat theme in %s\n' "$flavour" "$pin_file" >&2
        return 1
      }
      # Restated from platforms/parrot-ctf/scripts/install-terminal.sh.
      printf 'https://raw.githubusercontent.com/catppuccin/bat/%s/themes/Catppuccin%%20%s.tmTheme\t%s\n' \
        "$commit" "$flavour" "$digest"
    done
    ;;
  scoop-installer)
    commit="$(pin_value "$pin_file" "$pin_key")" || return 1
    digest="$(pin_value "$pin_file" InstallerSha256)" || return 1
    # Restated from platforms/windows/install.ps1.
    printf 'https://raw.githubusercontent.com/ScoopInstaller/Install/%s/install.ps1\t%s\n' \
      "$commit" "$digest"
    ;;
  catppuccin-tmux | catppuccin-kde)
    printf -- '-\tcloned by git at the pinned tag; neither a commit nor a digest is pinned beside it\n'
    ;;
  netcoredbg-legacy-release)
    printf -- '-\tthe macOS debugger integration fixture takes the release archive as served\n'
    ;;
  *)
    printf 'no coherence rule for %s; say in scripts/check-pin-freshness.sh what it pins a digest for\n' \
      "$source" >&2
    return 1
    ;;
  esac
}

# coherence_report: the --coherence run, over the same manifest rows.
coherence_report() {
  local rows source probe pin_file pin_key pairs url digest actual work_dir
  local checked=0 failed=0 undigested=0
  local -a report=()

  rows="$(manifest_values "$PIN_FRESHNESS_MANIFEST" source,probe,pin_file,pin_key)" ||
    die "Could not read the pin freshness manifest: $PIN_FRESHNESS_MANIFEST"
  [[ -n "$rows" ]] || die "The pin freshness manifest has no rows: $PIN_FRESHNESS_MANIFEST"

  work_dir="$(mktemp -d)" || die "Could not create a private download directory"
  chmod 700 -- "$work_dir"
  # shellcheck disable=SC2064 # The directory is fixed now, and removed on exit.
  trap "rm -rf -- '$work_dir'" EXIT

  while IFS=$'\t' read -r source probe pin_file pin_key; do
    [[ -n "$source" && "$probe" != none ]] || continue
    if ! pairs="$(coherence_pairs "$source" "$pin_file" "$pin_key")" || [[ -z "$pairs" ]]; then
      report+=("$source"$'\t'"-"$'\t'"pin unreadable")
      failed=$((failed + 1))
      continue
    fi
    while IFS=$'\t' read -r url digest; do
      if [[ "$url" == - ]]; then
        report+=("$source"$'\t'"-"$'\t'"no digest pinned: $digest")
        undigested=$((undigested + 1))
        continue
      fi
      if [[ ! "$digest" =~ ^[0-9a-f]{64}$ || "$url" != https://* ]]; then
        report+=("$source"$'\t'"${url:-?}"$'\t'"not a pinned address and SHA-256")
        failed=$((failed + 1))
        continue
      fi
      if [[ "$list_only" == true ]]; then
        report+=("$source"$'\t'"$url"$'\t'"$digest")
        checked=$((checked + 1))
        continue
      fi
      rm -f -- "$work_dir/artifact"
      # The address is the row's pinned one; its source is the row itself.
      # network-source: caller-provided
      if ! (fetch_to_file "$url" "$work_dir/artifact" "$source") 2>>"$work_dir/errors"; then
        report+=("$source"$'\t'"$url"$'\t'"download failed")
        failed=$((failed + 1))
        continue
      fi
      actual="$(fetch_sha256 "$work_dir/artifact")" || actual=""
      if [[ "$actual" == "$digest" ]]; then
        report+=("$source"$'\t'"$url"$'\t'"coherent")
        checked=$((checked + 1))
      else
        report+=("$source"$'\t'"$url"$'\t'"MISMATCH: pinned $digest, served ${actual:-nothing}")
        failed=$((failed + 1))
      fi
    done <<<"$pairs"
  done <<<"$rows"

  printf 'Pinned digests, against what their pinned addresses serve\n\n'
  printf '%s\n' "${report[@]}" | awk -F'\t' '{ printf "  %s  %s\n    %s\n", $1, $2, $3 }'
  printf '\n%d %s, %d without a pinned digest, %d could not be confirmed.\n' \
    "$checked" "$([[ "$list_only" == true ]] && printf listed || printf coherent)" \
    "$undigested" "$failed"
  if [[ -s "$work_dir/errors" ]]; then
    printf '\nDownload errors:\n'
    sed 's/^/  /' "$work_dir/errors"
  fi
  ((failed == 0))
}

if [[ "$list_only" == true && "$coherence" != true ]]; then
  printf -- '--list is only meaningful with --coherence.\n' >&2
  usage >&2
  exit 2
fi
if [[ "$coherence" == true ]]; then
  # shellcheck source=../common/lib/fetch.sh
  source "$repo_root/common/lib/fetch.sh"
  coherence_report
  exit
fi

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
