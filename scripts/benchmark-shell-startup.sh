#!/usr/bin/env bash
set -euo pipefail

# Measure Zsh startup so optimization work targets a measured problem.
#
# Issue #157 asks for a recorded benchmark and threshold before any startup
# tuning. This script is deliberately not part of ./scripts/test.sh: wall-clock
# timing is machine- and load-dependent, and a timing assertion in the fast
# mocked suite would be a flaky gate rather than evidence.
#
# It measures three shapes that behave very differently:
#
#   interactive-login  zsh -l -i -c exit  .zshenv + .zprofile + .zshrc, the
#                                         cost a new terminal window or tab
#                                         actually pays: a terminal starts a
#                                         login shell (see .zshrc)
#   interactive        zsh -i -c exit     .zshenv + .zshrc, a shell started
#                                         inside one, which skips .zprofile
#   non-interactive    zsh -c exit        .zshenv only, the cost every script
#                                         and every tool subshell pays
#
# This used to call the second shape the terminal's cost. The two differ only
# by .zprofile, about 0.1 ms today, but that is exactly where the next login
# PATH change goes, and measuring the non-login shape alone would never have
# seen it (#539).

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"

runs=20
interactive_login_threshold_ms=0
interactive_threshold_ms=0
non_interactive_threshold_ms=0

usage() {
  cat <<'EOF_USAGE'
Usage: ./scripts/benchmark-shell-startup.sh [options]

Options:
  --runs N                  Measurements per shape (default: 20)
  --interactive-login-ms N  Fail if the interactive login median exceeds N ms
  --interactive-ms N        Fail if the interactive median exceeds N ms
  --non-interactive-ms N    Fail if the non-interactive median exceeds N ms
  -h, --help                Show this help

Without a threshold the script only reports. Thresholds exist so a recorded
budget can be re-checked on the same machine after a change.
EOF_USAGE
}

while (($#)); do
  case "$1" in
  --runs)
    [[ $# -ge 2 ]] || die '--runs requires a value'
    runs="$2"
    shift 2
    ;;
  --interactive-login-ms)
    [[ $# -ge 2 ]] || die '--interactive-login-ms requires a value'
    interactive_login_threshold_ms="$2"
    shift 2
    ;;
  --interactive-ms)
    [[ $# -ge 2 ]] || die '--interactive-ms requires a value'
    interactive_threshold_ms="$2"
    shift 2
    ;;
  --non-interactive-ms)
    [[ $# -ge 2 ]] || die '--non-interactive-ms requires a value'
    non_interactive_threshold_ms="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
done

for value in "$runs" "$interactive_login_threshold_ms" "$interactive_threshold_ms" \
  "$non_interactive_threshold_ms"; do
  [[ "$value" =~ ^[0-9]+$ ]] || die "Expected a non-negative integer, got: $value"
done
((runs > 0)) || die '--runs must be at least 1'

require_command zsh

# Milliseconds since the epoch, without assuming GNU date's %N is available.
now_ms() {
  zsh -f -c 'zmodload zsh/datetime; printf "%.0f\n" $(( EPOCHREALTIME * 1000 ))'
}

measure() {
  local label="$1"
  shift
  local -a samples=()
  local index start finish

  for ((index = 0; index < runs; index++)); do
    start="$(now_ms)"
    "$@" >/dev/null 2>&1 || die "$label shell exited non-zero; startup is broken"
    finish="$(now_ms)"
    samples+=("$((finish - start))")
  done

  printf '%s\n' "${samples[@]}" | sort -n
}

summarize() {
  local label="$1" threshold="$2"
  shift 2
  local -a sorted=()
  local sample total=0 median measured

  # Command substitution, not process substitution: a shell that fails to
  # start must fail the benchmark instead of silently producing no samples.
  measured="$(measure "$label" "$@")" ||
    die "$label shell could not be measured"
  while IFS= read -r sample; do sorted+=("$sample"); done <<<"$measured"
  ((${#sorted[@]} == runs)) ||
    die "$label produced ${#sorted[@]} samples, expected $runs"

  for sample in "${sorted[@]}"; do total=$((total + sample)); done
  median="${sorted[$((${#sorted[@]} / 2))]}"

  printf '%-18s runs=%-4s min=%-6s median=%-6s max=%-6s mean=%s\n' \
    "$label" "$runs" "${sorted[0]}" "$median" "${sorted[-1]}" \
    "$((total / ${#sorted[@]}))"

  if ((threshold > 0)) && ((median > threshold)); then
    warn "$label median ${median}ms exceeds the ${threshold}ms budget"
    return 1
  fi
}

info "Benchmarking Zsh startup ($runs runs per shape, milliseconds)"

status=0
summarize interactive-login "$interactive_login_threshold_ms" zsh -l -i -c exit || status=1
summarize interactive "$interactive_threshold_ms" zsh -i -c exit || status=1
summarize non-interactive "$non_interactive_threshold_ms" zsh -c exit || status=1

if ((status == 0)); then
  success 'Zsh startup benchmark completed'
else
  die 'Zsh startup exceeded the requested budget'
fi
