#!/usr/bin/env bash
# git tidy (#560): which local branches it deletes, and which it never touches.
#
# Every branch shape a pull request workflow leaves behind is built in a
# throwaway bare origin. A second clone stands in for the forge: it lands each
# pull request the way GitHub's merge, squash and rebase buttons do and then
# deletes the remote branch, as the repository's delete_branch_on_merge
# setting does. The clone under test only ever fetches.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git python3
# Reached as `git tidy`, the way a user runs it: Git finds git-tidy on PATH.
PATH="$repo_root/bin/.local/bin:$PATH"

# --- Fixtures --------------------------------------------------------------

# isolate_git <root>: Git configuration from this fixture only, never the
# machine's, so a signing key, hook path or default branch there cannot leak in.
isolate_git() {
  local root="$1"
  export HOME="$root/home"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$root/gitconfig"
  git config --global user.name "Fixture"
  git config --global user.email "fixture@example.invalid"
  git config --global commit.gpgsign false
  git config --global init.defaultBranch main
  git config --global advice.detachedHead false
}

# commit <repo> <file> <content>: one commit writing <content> to <file>.
commit() {
  local repo="$1" file="$2" content="$3"
  printf '%s\n' "$content" >"$repo/$file"
  git -C "$repo" add -- "$file"
  git -C "$repo" commit --quiet -m "$file: $content"
}

# branch <name> <commits...>: in the work clone, a branch from origin/main with
# one commit per argument, each to its own file, pushed with an upstream.
branch() {
  local name="$1"
  shift
  git -C "$work" switch --quiet -c "$name" origin/main
  local content
  for content in "$@"; do
    commit "$work" "${name//\//-}-$content.txt" "$content"
  done
  git -C "$work" push --quiet -u origin "$name" 2>/dev/null
  git -C "$work" switch --quiet --detach
}

# land <name> <merge|squash|rebase|close>: the forge resolves the pull request
# for <name>, then deletes the remote branch.
land() {
  local name="$1" how="$2"
  git -C "$forge" fetch --quiet origin
  git -C "$forge" switch --quiet main
  git -C "$forge" reset --quiet --hard origin/main
  case "$how" in
  merge) git -C "$forge" merge --quiet --no-ff -m "Merge $name" "origin/$name" ;;
  squash)
    git -C "$forge" merge --quiet --squash "origin/$name" >/dev/null 2>&1
    git -C "$forge" commit --quiet -m "$name (squashed)"
    ;;
  rebase) git -C "$forge" cherry-pick "origin/main..origin/$name" >/dev/null ;;
  close) ;;
  esac
  git -C "$forge" push --quiet origin main
  git -C "$forge" push --quiet origin --delete "$name"
}

# advance_main <file> <content>: someone else's pull request lands on main.
advance_main() {
  git -C "$forge" fetch --quiet origin
  git -C "$forge" switch --quiet main
  git -C "$forge" reset --quiet --hard origin/main
  commit "$forge" "$1" "$2"
  git -C "$forge" push --quiet origin main
}

# new_fixture: a bare origin with one commit on main, the forge clone and the
# work clone, which is where git tidy runs.
new_fixture() {
  test_new_root
  isolate_git "$TEST_ROOT"
  origin="$TEST_ROOT/origin.git"
  forge="$TEST_ROOT/forge"
  work="$TEST_ROOT/work"
  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$forge" 2>/dev/null
  commit "$forge" README.md seed
  git -C "$forge" push --quiet -u origin main
  git clone --quiet "$origin" "$work"
}

# section <heading-prefix>: the branch names listed under a heading of the last
# run's output, one per line, in order.
section() {
  awk -v heading="$1" '
    index($0, heading) == 1 { listing = 1; next }
    listing && /^  [^ ]/ { print $1; next }
    listing { exit }
  ' <<<"$TEST_OUTPUT"
}

assert_deleted_list() {
  assert_eq "$1" "$(section 'These ' | paste -sd' ' -)" 'branches listed for deletion'
}

assert_kept_list() {
  assert_eq "$1" "$(section 'Kept:' | paste -sd' ' -)" 'branches listed as kept'
}

# assert_row <name> <reason>: the last run listed <name> with that reason.
assert_row() {
  local name="$1" reason="$2" line
  while IFS= read -r line; do
    if [[ "$line" =~ ^\ \ "$name"\ +[0-9a-f]+\ \ (.*)$ ]]; then
      assert_eq "$reason" "${BASH_REMATCH[1]}" "reason given for $name"
      return
    fi
  done <<<"$TEST_OUTPUT"
  _test_die "no row for $name in:"$'\n'"$TEST_OUTPUT"
}

local_branches() {
  git -C "$work" for-each-ref --format='%(refname:lstrip=2)' refs/heads | paste -sd' ' -
}

# tidy_in_terminal <answer> [argument...]: run git tidy on a pseudo-terminal
# and type <answer> at its prompt, as a person at the keyboard would.
tidy_in_terminal() {
  local answer="$1"
  shift
  # shellcheck disable=SC2016 # Python source, not shell.
  run_capture python3 -c '
import os, pty, sys
answer = sys.argv[1].encode() + b"\n"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("git", ["git", "tidy", *sys.argv[2:]])
output, answered = b"", False
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    output += chunk
    if not answered and b"[y/N] " in output:
        os.write(fd, answer)
        answered = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(output.decode().replace("\r\n", "\n"))
sys.exit(os.waitstatus_to_exitcode(status))
' "$answer" "$@"
}

# --- Every shape a pull request workflow leaves behind ---------------------

new_fixture

# Landed, each the way one of the forge's merge buttons lands it.
branch feat/merge-commit one
land feat/merge-commit merge
branch feat/rebase one two
land feat/rebase rebase
branch feat/squash one two three
land feat/squash squash

# Squash-merged, then main rewrote the same lines: no merge would be a no-op,
# but the squash commit is still the branch's change.
branch feat/squash-edited one two
land feat/squash-edited squash
advance_main feat-squash-edited-one.txt rewritten

# Squash-merged, then main was merged back into the branch. The squash commit
# is now reachable from the branch, so only the merge no-op proves it.
branch feat/synced one two
land feat/synced squash
git -C "$work" fetch --quiet origin
git -C "$work" switch --quiet feat/synced
git -C "$work" merge --quiet --no-edit origin/main
git -C "$work" switch --quiet --detach

# Created from main and never committed to.
git -C "$work" branch --quiet feat/fresh origin/main

# A branch reused for a second pull request: the first one landed and took the
# remote branch with it, and the next one's work is local so far.
branch claude/reused one
land claude/reused merge
git -C "$work" switch --quiet claude/reused
commit "$work" claude-reused-next.txt next
git -C "$work" switch --quiet --detach

branch claude/reused-squash one
land claude/reused-squash squash
git -C "$work" switch --quiet claude/reused-squash
commit "$work" claude-reused-squash-next.txt next
commit "$work" claude-reused-squash-after.txt after
git -C "$work" switch --quiet --detach

# Closed without merging; the remote branch is gone all the same.
branch feat/closed one
land feat/closed close

# Still open, and never pushed.
branch feat/open one
git -C "$work" switch --quiet -c wip/local origin/main
commit "$work" wip.txt local
git -C "$work" switch --quiet --detach

# Already on main, but checked out: in another worktree, and in this one. The
# first has no upstream at all, the second a gone one.
git -C "$work" fetch --quiet origin
git -C "$work" branch --quiet --no-track feat/in-worktree origin/main
git -C "$work" worktree add --quiet "$HOME/other-worktree" feat/in-worktree
branch feat/current one
land feat/current merge
git -C "$work" switch --quiet feat/current

# The clone's own main is behind origin and must still never be deleted.
git -C "$work" branch --quiet --force main "$(git -C "$work" rev-list --max-parents=0 HEAD)"

all_branches="claude/reused claude/reused-squash feat/closed feat/current feat/fresh feat/in-worktree feat/merge-commit feat/open feat/rebase feat/squash feat/squash-edited feat/synced main wip/local"
assert_eq "$all_branches" "$(local_branches)" 'fixture branches'

expected_deleted="feat/fresh feat/merge-commit feat/rebase feat/squash feat/squash-edited feat/synced"
expected_kept="claude/reused claude/reused-squash feat/closed feat/current feat/in-worktree"

# --- The list, before anything is deleted ----------------------------------

cd "$work"
run_capture git tidy --dry-run
assert_success
assert_contains "$TEST_OUTPUT" 'These 6 branches are already on origin/main and will be deleted:'
assert_deleted_list "$expected_deleted"
assert_kept_list "$expected_kept"
assert_row feat/fresh 'merged into origin/main'
assert_row feat/merge-commit 'merged into origin/main'
assert_row feat/rebase 'every commit is already on origin/main'
assert_row feat/squash 'squash-merged into origin/main'
assert_row feat/squash-edited 'squash-merged into origin/main'
assert_row feat/synced 'merging it into origin/main changes nothing'
assert_row claude/reused 'remote branch is gone, but 1 commit is not on origin/main'
assert_row claude/reused-squash 'remote branch is gone, but 2 commits are not on origin/main'
assert_row feat/closed 'remote branch is gone, but 1 commit is not on origin/main'
assert_row feat/current 'merged into origin/main, but it is the current branch'
assert_row feat/in-worktree 'merged into origin/main, but checked out in ~/other-worktree'
assert_not_contains "$TEST_OUTPUT" 'feat/open'
assert_not_contains "$TEST_OUTPUT" 'wip/local'
assert_contains "$TEST_OUTPUT" 'Dry run: nothing deleted.'
assert_eq "$all_branches" "$(local_branches)" 'a dry run deletes nothing'

# The fetch is what made the pruned upstreams visible as gone.
[[ -z "$(git for-each-ref refs/remotes/origin/feat/closed)" ]] ||
  _test_die 'git tidy did not fetch with --prune first'

# --- Without a terminal it never deletes -----------------------------------

run_capture git tidy </dev/null
assert_success
assert_deleted_list "$expected_deleted"
assert_contains "$TEST_OUTPUT" 'Not a terminal: nothing deleted. Re-run with --yes to delete them.'
assert_eq "$all_branches" "$(local_branches)" 'a run without a terminal deletes nothing'

# --- At the prompt, anything but yes deletes nothing -----------------------

tidy_in_terminal n
assert_success
assert_contains "$TEST_OUTPUT" 'Delete these 6 branches? [y/N] '
assert_contains "$TEST_OUTPUT" 'Nothing deleted.'
assert_eq "$all_branches" "$(local_branches)" 'answering no deletes nothing'

# --- --yes deletes exactly the listed branches -----------------------------

squash_tip="$(git rev-parse feat/squash)"
run_capture git tidy --yes
assert_success
assert_contains "$TEST_OUTPUT" "restore: git branch feat/squash $squash_tip"
assert_eq "claude/reused claude/reused-squash feat/closed feat/current feat/in-worktree feat/open main wip/local" \
  "$(local_branches)" 'branches left after --yes'
assert_eq feat/current "$(git symbolic-ref --short HEAD)" 'the current branch'

run_capture git tidy --yes
assert_success
assert_contains "$TEST_OUTPUT" 'Nothing to tidy: no local branch is already on origin/main.'
assert_kept_list "$expected_kept"

# --- Answering yes at the prompt deletes -----------------------------------

git branch --quiet feat/later origin/main
tidy_in_terminal y
assert_success
assert_contains "$TEST_OUTPUT" 'This branch is already on origin/main and will be deleted:'
assert_contains "$TEST_OUTPUT" 'Delete this branch? [y/N] '
assert_contains "$TEST_OUTPUT" 'Deleted feat/later'
[[ -z "$(git for-each-ref refs/heads/feat/later)" ]] || _test_die 'answering yes did not delete feat/later'

# --- With no remote, local main is the base --------------------------------

test_new_root
isolate_git "$TEST_ROOT"
solo="$TEST_ROOT/solo"
git init --quiet "$solo"
commit "$solo" README.md seed
git -C "$solo" switch --quiet -c feat/done
commit "$solo" landed.txt landed
git -C "$solo" switch --quiet main
git -C "$solo" merge --quiet --no-ff -m 'Merge feat/done' feat/done
git -C "$solo" branch --quiet feat/todo
git -C "$solo" switch --quiet feat/todo
commit "$solo" todo.txt todo
git -C "$solo" switch --quiet main
cd "$solo"
run_capture git tidy --yes
assert_success
assert_contains "$TEST_OUTPUT" 'This branch is already on main and will be deleted:'
assert_eq "feat/todo main" "$(git for-each-ref --format='%(refname:lstrip=2)' refs/heads | paste -sd' ' -)" \
  'branches left with no remote'

# --- Usage -----------------------------------------------------------------

run_capture git tidy -h
assert_success
assert_contains "$TEST_OUTPUT" 'Usage: git tidy [--yes | --dry-run]'

run_capture git tidy --sideways
assert_status 2
assert_contains "$TEST_OUTPUT" 'Unknown argument: --sideways'

cd "$TEST_ROOT"
run_capture git tidy --dry-run
assert_status 2
assert_contains "$TEST_OUTPUT" 'git tidy: not inside a Git repository'
