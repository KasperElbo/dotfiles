#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/common/assets/agent-worktree"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

project="$test_root/project"
xdg_data="$test_root/data"
mkdir -p "$project" "$xdg_data"

git -C "$project" init -q -b main
git -C "$project" config user.name Test
git -C "$project" config user.email test@example.invalid
printf 'hello\n' >"$project/file.txt"
git -C "$project" add file.txt
git -C "$project" commit -qm 'Initial commit'

env=(env "XDG_DATA_HOME=$xdg_data")
run() { (cd "$project" && "${env[@]}" "$helper" "$@"); }

project_name="$(basename "$project")"
worktrees_root="$xdg_data/dotfiles/agent-worktrees/$project_name"

# --- new: creates an isolated worktree and namespaced branch ---------------

alpha_path="$(run new alpha)"
[[ "$alpha_path" == "$worktrees_root/alpha" ]] || {
  printf 'Unexpected worktree path: %s\n' "$alpha_path" >&2
  exit 1
}
[[ -d "$alpha_path" ]]
git -C "$project" show-ref --verify --quiet refs/heads/agents/alpha

# --- new: refuses to reuse an existing branch/path -------------------------

if run new alpha >"$test_root/dup.log" 2>&1; then
  printf 'agent-worktree new allowed reusing an existing branch\n' >&2
  exit 1
fi
grep -Fq 'already exists' "$test_root/dup.log"

# --- new: rejects unsafe names ----------------------------------------------

if run new '../escape' >"$test_root/badname.log" 2>&1; then
  printf 'agent-worktree new accepted an unsafe name\n' >&2
  exit 1
fi
grep -Fq 'name must match' "$test_root/badname.log"

# --- list: shows the created worktree ---------------------------------------

list_output="$(run list)"
[[ "$list_output" == *"$alpha_path"* ]] || {
  printf 'agent-worktree list did not show %s:\n%s\n' "$alpha_path" "$list_output" >&2
  exit 1
}

# --- remove: refuses a dirty worktree ---------------------------------------

printf 'dirty\n' >>"$alpha_path/file.txt"

if run remove alpha >"$test_root/dirty.log" 2>&1; then
  printf 'agent-worktree remove allowed removing a dirty worktree\n' >&2
  exit 1
fi
grep -Fq 'uncommitted changes' "$test_root/dirty.log"

# --- remove: refuses committed-but-unlanded work without --force -----------

git -C "$alpha_path" commit -qam 'Work in progress'

if run remove alpha >"$test_root/unlanded.log" 2>&1; then
  printf 'agent-worktree remove allowed removing unlanded work without --force\n' >&2
  exit 1
fi
grep -Fq 'neither pushed to an upstream nor' "$test_root/unlanded.log"

# --- remove: succeeds once the branch is landed on another local branch ----

git -C "$project" merge -q --no-edit agents/alpha
run remove alpha
[[ ! -e "$alpha_path" ]]
git -C "$project" show-ref --verify --quiet refs/heads/agents/alpha ||
  {
    printf 'agent-worktree remove deleted the branch; it must only remove the worktree\n' >&2
    exit 1
  }

# --- remove --force: discards uncommitted/unlanded work on request ---------

bravo_path="$(run new bravo)"
printf 'scratch\n' >"$bravo_path/scratch.txt"
git -C "$bravo_path" add scratch.txt
git -C "$bravo_path" commit -qm 'Unlanded scratch work'

run remove bravo --force
[[ ! -e "$bravo_path" ]]
git -C "$project" show-ref --verify --quiet refs/heads/agents/bravo

# --- prune: does not error on stale metadata --------------------------------

run prune

# --- outside a Git repository: fails clearly --------------------------------

outside="$test_root/not-a-repo"
mkdir -p "$outside"
if (cd "$outside" && "${env[@]}" "$helper" new charlie) \
  >"$test_root/outside.log" 2>&1; then
  printf 'agent-worktree ran outside a Git repository\n' >&2
  exit 1
fi
grep -Fq 'not inside a Git repository' "$test_root/outside.log"

printf 'agent-worktree safety tests passed.\n'
