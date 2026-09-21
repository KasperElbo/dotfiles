# Neovim / LazyVim

Neovim itself is owned by whatever native provider the platform already
uses, not by a single shared mechanism: DNF on Fedora and Fedora WSL,
Homebrew (`Brewfile`) on macOS, and a pinned mise tool
(`nvim = "0.12.5"` in `platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml`)
on the Parrot CTF guest — the one deliberate exception, because Parrot 7.3
only packages Neovim 0.10.x and this configuration requires 0.12 or newer.

That floor is stated once, in
[`config/tool-floors.tsv`](../../config/tool-floors.tsv), and is what the test
runner, `common/install-neovim-tools.sh` and every platform verifier check
against; no shell script repeats it, and `scripts/validate-tool-floors.py`
fails the build if any documentation page states a different minimum than the
registry does, or if the Parrot mise pin above drops below it.

The editor configuration uses:

```text
LazyVim
lazy.nvim
Mason
Treesitter
Conform
nvim-dap
```

`vim.pack` is intentionally not used because LazyVim is built around `lazy.nvim`.

## How the editor is provisioned

The tracked config selects between two profiles, `workstation` (the default)
and `parrot-ctf`, in
[`lua/config/profile.lua`](../../nvim-lazyvim/.config/nvim/lua/config/profile.lua).
The active profile is `$DOTFILES_NVIM_PROFILE` if set, otherwise the contents
of the marker file `~/.config/dotfiles/neovim-profile` written by the
installer, otherwise `workstation`. Each profile declares its own LazyVim
extras, plugin spec directory, Mason package inventory, and lockfile —
`lazyvim.json` itself always reports `"extras": []`, because extras are
selected by the profile module rather than LazyVim's own extras manager:

| Profile | Extras | Lockfile | Mason inventory |
| --- | --- | --- | --- |
| `workstation` | dap.core, formatting.prettier, lang.angular, lang.json, lang.markdown, lang.python, lang.tex, lang.yaml, linting.eslint, test.core | `lazy-lock.json` | `mason-packages.txt` |
| `parrot-ctf` | dap.core, lang.python, test.core (a deliberately reduced set — no JSON/Prettier/Node-based tooling) | `profiles/parrot-ctf/lazy-lock.json` | `profiles/parrot-ctf/mason-packages.txt` |

[`common/install-neovim-tools.sh`](../../common/install-neovim-tools.sh) does
the actual bootstrap, headless and in three phases, each run through
`timeout` with a default 20-minute budget per phase
(`NEOVIM_BOOTSTRAP_TIMEOUT`, default `20m`):

1. **Prepare Mason** — restores only `mason.nvim` via `Lazy! restore`, with
   `nvim-treesitter` disabled, so Mason's API is available without letting
   LazyVim's own asynchronous Treesitter installer race it for
   `tree-sitter-cli`.
2. **Install Mason editor tools** — loads Mason directly
   (`common/bootstrap-mason.lua`) and blocks until the profile's complete
   Mason package inventory, including `tree-sitter-cli`, has converged.
3. **Restore LazyVim plugins** — re-enables the normal plugin spec (with
   Mason's `bin/` already on `PATH`) and verifies a headless startup.

If the restore log shows LazyVim attempting its own competing
`tree-sitter-cli` install, the bootstrap fails loudly rather than letting two
installers race.

## Navigation

```text
<leader>fp    projects
<leader>ff    files
<leader>/     grep
<leader>,     buffers
<leader>fr    recent files
<leader>e     explorer

Shift-h       previous buffer
Shift-l       next buffer
<leader>bb    previous/other buffer
<leader>bd    delete current buffer
<leader>bi    delete invisible buffers

Ctrl-h/j/k/l  move between windows
```

The project picker keeps existing buffers open. This is standard Neovim behavior and is intentionally left stock.

## Sessions

```text
<leader>qs    restore current-directory session
<leader>qS    select saved session
<leader>ql    restore last session
<leader>qd    do not save current session
```

## Code navigation

```text
gd            definition
gr            references
gI            implementation
gy            type definition
K             hover

<leader>ca    code action
<leader>cr    rename

Ctrl-o        jump backward
Ctrl-i        jump forward

]d / [d       diagnostic next/previous
]e / [e       error next/previous
]w / [w       warning next/previous

s             Flash jump
S             Treesitter-aware Flash jump
```

## Quitting

Use:

```text
<leader>qq
```

or:

```vim
:qa
```

Avoid using `:q` merely to move between files; `:q` closes a window.
