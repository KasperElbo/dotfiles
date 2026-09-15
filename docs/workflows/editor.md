# Neovim / LazyVim

Neovim is installed through DNF.

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
