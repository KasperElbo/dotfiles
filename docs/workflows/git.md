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
