#!/usr/bin/env bash

# The update behind ./update (#561): fast-forward this checkout's main, list the
# pull requests that landed since the installed revision, and reapply the
# remembered configuration with ./install.sh --rerun.
#
# "Up to date" means what ./doctor means by it: the lifecycle record's
# `revision` is HEAD and the run that wrote it finished. Whether the pull
# brought anything is not the question, because a checkout moved by a plain
# `git pull`, by `./update --dry-run`, or by a failed installation is exactly
# as far behind as one that has not been pulled.
#
# Like ./doctor, this can start under Apple's Bash 3.2 on macOS, so everything
# down to the modern-Bash guard below stays inside that dialect.

script_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
repo_root="$(cd -- "$(dirname -- "$script_path")/.." && pwd)"

# shellcheck source=../common/lib/modern-bash.sh
. "$repo_root/common/lib/modern-bash.sh"
modern_bash_reexec update "$script_path" "$@" || exit 2

set -euo pipefail

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"
# shellcheck source=../common/lib/install-lifecycle.sh
source "$repo_root/common/lib/install-lifecycle.sh"

usage() {
  cat <<'USAGE'
Usage: ./update [--dry-run]

Fast-forward this checkout's main, list the pull requests merged since the
installed revision, then reapply this machine's last successful configuration
with ./install.sh --rerun.

  --dry-run   Pull, list, and preview with ./install.sh --rerun --dry-run.
              The checkout moves; nothing is installed.
  -h, --help  Show this help.
USAGE
}

git_repo() {
  git -C "$repo_root" "$@"
}

short() {
  git_repo rev-parse --short "$1" 2>/dev/null || printf '%s\n' "$1"
}

# merged_pull_requests <from> <to>: one line per commit on main's first-parent
# path from <from> to <to>, oldest first. Main has landed pull requests both
# ways: as squash commits titled `Title (#N)` until 2026-09-22 and again since
# #567, and as `Merge pull request #N from <branch>` merges, whose title is the
# first line of the body because the subject only names the branch. Following
# first parents keeps the commits of a merged branch, and pull requests merged
# into an integration branch rather than into main, out of the list. Anything
# else is a commit pushed straight to main and is shown as one.
merged_pull_requests() {
  git_repo log --first-parent --reverse --format='%h%x1f%s%x1f%b%x1e' "$1..$2" |
    awk '
      BEGIN { RS = "\036"; FS = "\037" }
      {
        sub(/^\n+/, "", $1)
        if ($1 == "") next
        if ($2 ~ /^Merge pull request #[0-9]+ from /) {
          match($2, /#[0-9]+/)
          number = substr($2, RSTART, RLENGTH)
          title = ""
          lines = split($3, body, "\n")
          for (i = 1; i <= lines; i++) {
            if (body[i] ~ /[^[:space:]]/) { title = body[i]; break }
          }
          if (title == "") title = substr($2, RSTART + RLENGTH + 1)
          printf "  %s %s\n", number, title
        } else if (match($2, / \(#[0-9]+\)$/)) {
          printf "  %s %s\n", substr($2, RSTART + 2, RLENGTH - 3), substr($2, 1, RSTART - 1)
        } else {
          printf "  %s %s (no pull request)\n", $1, $2
        }
      }'
}

main() {
  local dry_run=false argument branch changes upstream
  local state status revision previous current
  local -a rerun=(--rerun)

  for argument in "$@"; do
    case "$argument" in
    --dry-run) dry_run=true ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      printf '\033[1;31mERROR:\033[0m Unknown option for ./update: %s\n' "$argument" >&2
      usage >&2
      return 2
      ;;
    esac
  done
  [[ "$dry_run" == false ]] || rerun+=(--dry-run)

  # Every refusal comes before the pull, so a refused ./update has changed
  # nothing, not even the checkout.
  if ! branch="$(git_repo symbolic-ref --quiet --short HEAD)"; then
    printf '\033[1;31mERROR:\033[0m ./update only updates main, and this checkout is on a detached HEAD.\n' >&2
    printf 'Switch with: git switch main\n' >&2
    return 1
  fi
  if [[ "$branch" != main ]]; then
    printf '\033[1;31mERROR:\033[0m ./update only updates main, and this checkout is on %s.\n' "$branch" >&2
    printf 'Switch with: git switch main\n' >&2
    return 1
  fi
  # Untracked files count: a pull that adds a file of the same name stops
  # halfway, and nothing a machine generates for itself lives in the tree
  # unignored.
  changes="$(git_repo status --porcelain)"
  if [[ -n "$changes" ]]; then
    printf '\033[1;31mERROR:\033[0m ./update refuses to pull over uncommitted changes:\n' >&2
    printf '%s\n' "$changes" >&2
    printf 'Commit, stash or remove them, then run ./update again.\n' >&2
    return 1
  fi
  # A machine with nothing to reapply would otherwise pull first and only then
  # hear from --rerun that it has nothing to do. This is the reader --rerun
  # itself uses, so the reasons and their wording are its own.
  if ! install_remembered_load; then
    printf 'Nothing was pulled or installed.\n' >&2
    return 1
  fi

  previous="$(git_repo rev-parse HEAD)"
  if ! git_repo pull --ff-only --quiet; then
    upstream="$(git_repo rev-parse --verify --quiet '@{upstream}' || true)"
    if [[ -n "$upstream" ]] && ! git_repo merge-base --is-ancestor HEAD "$upstream"; then
      printf '\033[1;31mERROR:\033[0m Local main has commits its upstream does not, and ./update only fast-forwards.\n' >&2
    else
      printf '\033[1;31mERROR:\033[0m git pull --ff-only failed.\n' >&2
    fi
    printf 'Nothing was installed.\n' >&2
    return 1
  fi
  current="$(git_repo rev-parse HEAD)"

  state="$(install_state_path)"
  revision="$(profile_state_read "$state" revision install)"
  status="$(install_state_optional "$state" status)"
  if [[ "$revision" == "$current" && "$status" == installed ]]; then
    printf 'Already up to date: main is at %s and that revision is installed.\n' "$(short "$current")"
    return 0
  fi

  if [[ "$previous" == "$current" ]]; then
    printf 'main is already at %s; the pull brought nothing new.\n' "$(short "$current")"
  else
    printf 'Pulled main %s..%s.\n' "$(short "$previous")" "$(short "$current")"
  fi
  # The record's revision is written when a run starts, so a failed run at an
  # older revision still names the revision it was applying.
  if [[ "$status" != installed ]]; then
    printf 'The last installation, of %s, is "%s".\n' "$(short "$revision")" "${status:-unrecorded}"
  fi
  if [[ "$revision" != "$current" ]]; then
    if git_repo merge-base --is-ancestor "$revision" "$current" 2>/dev/null; then
      printf 'Merged since the installed revision %s:\n' "$(short "$revision")"
      merged_pull_requests "$revision" "$current"
    else
      printf 'The installed revision %s is not in main'"'"'s history, so what changed since it cannot be listed.\n' "$revision"
    fi
  fi

  printf '\nRunning ./install.sh %s\n' "${rerun[*]}"
  exec "$repo_root/install.sh" "${rerun[@]}"
}

# The pull can replace this file. Bash reads a script as it runs it, so all of
# the work is in a function that is parsed whole before the pull happens.
main "$@"
