# Git and GitHub workflow

Responsibilities:

```text
Git
    source control

Lazygit
    repo-wide staging, commits, rebases, conflict work

LazyVim / Gitsigns / Snacks
    in-buffer hunks, blame, history, diff navigation

gh
    GitHub PRs, issues, checks, review, API
```

Shared Git defaults include:

- default branch `main`
- fetch pruning
- automatic upstream setup on first push
- rerere
- histogram diff algorithm
- Delta pager
- Neovim as editor
- conditional work identity includes

Typical GitHub CLI workflow:

```bash
gh pr status
gh pr list
gh pr create --fill
gh pr view
gh pr checks
gh pr checks --watch
gh pr checkout 123
gh pr review 123
```

Useful LazyVim Git mappings:

```text
<leader>gg    Lazygit

]h            next Git hunk
[h            previous Git hunk

<leader>ghp   preview hunk
<leader>ghs   stage hunk
<leader>ghr   reset hunk

<leader>gB    open current file/line on GitHub
<leader>gY    copy GitHub URL
```

`<leader>gB` and `<leader>gY` come from snacks.nvim, which LazyVim always
loads; they open or copy a GitHub URL and need no GitHub plugin.

Fugitive and Octo are intentionally not installed at present, so there is
no in-editor pull-request or issue browser; `gh` above covers that from the
shell.

Multi-agent work (see [the AI profile guide](../profiles/ai.md)), when
Treehouse is installed, uses isolated worktrees managed by `treehouse`
rather than your current branch/checkout. It does not change the shared Git
defaults above.

## Cleaning up merged branches

Once its pull request lands, a branch has nothing left to do, but it stays in
every checkout that had it. `git tidy` deletes the local ones whose work is
already on the default branch:

```text
$ git tidy
These 3 branches are already on origin/main and will be deleted:
  feat/merge-commit  4de0c7c  merged into origin/main
  feat/rebase        3a20ef9  every commit is already on origin/main
  feat/squash        78ac1a6  squash-merged into origin/main

Kept:
  claude/reused      fca09d5  remote branch is gone, but 1 commit is not on origin/main
  feat/in-worktree   c7721dd  merged into origin/main, but checked out in ~/other-worktree

Delete these 3 branches? [y/N] y

Deleted feat/merge-commit  restore: git branch feat/merge-commit 4de0c7c72f604ad6b421b475720428261b5eb518
...
```

It first runs `git fetch --prune origin`, then compares each local branch
against `origin/HEAD`, which is `origin/main` here. It falls back to the last
fetched state when the fetch fails, and to the local `main` in a repository
with no `origin`. A branch is already on the default branch when any of these
holds:

- its tip is reachable from it, which is a merge-commit merge or a branch
  that was never committed to
- every commit has an equal patch there, which is a rebase merge
- its whole change, taken as one patch, equals one commit there, which is a
  squash merge
- merging it would change nothing, which catches a squash merge that the
  branch later merged back in

That covers every merge button GitHub offers without asking GitHub, so it
works offline and needs no `gh` login.

It never deletes:

- the current branch
- the local branch with the default branch's name
- a branch checked out in any worktree; it names the worktree instead and
  leaves removing it to whatever made it, such as Treehouse
- a remote branch; only local branches are deleted

The **Kept** list also shows each branch whose remote branch is gone but whose
work is not on the default branch. That is usually a branch reused for a second
pull request after the first one merged and took the remote branch with it, or
a pull request closed without merging.

Each deletion prints the command that restores the branch. A branch that moved
after the list was shown is kept rather than deleted.

| Command | What it does |
| --- | --- |
| `git tidy` | list, then ask before deleting |
| `git tidy --dry-run` | list only |
| `git tidy --yes` | list, then delete without asking |
| `git tidy -h` | usage |

Without a terminal to answer the prompt, as in a script or an agent's shell,
plain `git tidy` lists the branches and deletes nothing; deleting from there
takes `--yes`. Use `-h` rather than `--help`: Git turns `git tidy --help` into
a search for a manual page, which does not exist.

`git tidy` needs Git 2.38 or newer for `git merge-tree --write-tree`, and
refuses to run on an older one.
