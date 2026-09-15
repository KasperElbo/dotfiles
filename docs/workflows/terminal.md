# Terminal: Ghostty and tmux

Ghostty is the terminal on Fedora and macOS, and Noctty plays the same role on
Windows for the WSL profile; tmux is used for persistence, not for splits.

## Ghostty

Ghostty is deliberately kept fairly minimal.

Current functional configuration includes:

```text
Zsh shell integration
cursor integration
sudo integration
title integration
SSH environment handling
SSH terminfo handling
Catppuccin theme
```

### Fonts

The Starship prompt uses the Catppuccin Powerline preset, whose separators and
icons are Nerd Font glyphs. Only the Parrot CTF guest installs a font (Hack
Nerd Font Mono, pinned and checksummed). On Fedora, Fedora WSL and macOS the
font is deliberately user-owned: this repository installs none, sets no
`font-family` in the tracked Ghostty configuration, and no verifier checks
glyph coverage.

Install any Nerd Font and select it in the terminal — Hack Nerd Font Mono is
what the Parrot guest uses and a safe default. Without one, the prompt renders
boxes or blanks where the glyphs should be.

Ghostty is the primary **local layout manager**:

- tabs
- splits
- terminal window layout
- terminal scrollback

tmux is not intended to duplicate this locally.

## Clipboard

On Linux/Wayland:

```text
Ctrl-Shift-C   copy
Ctrl-Shift-V   paste
```

Inside Neovim, prefer Neovim registers for editor content.

The system clipboard register is:

```vim
"+
```

Examples:

```vim
"+yy
"+p
```

---

## tmux

tmux is intentionally a thin persistence/session layer.

Primary use cases:

- persistent local sessions
- long-running processes
- remote SSH sessions
- recovering work after terminal disconnects

Ghostty remains the preferred local layout/split manager.

Useful commands:

```bash
tmux new -As valhal
tmux ls
tmux attach -t valhal
tmux kill-session -t valhal
```

Important default keys:

```text
Ctrl-b d    detach
Ctrl-b s    choose session
Ctrl-b $    rename session
Ctrl-b [    copy/scroll mode
Ctrl-b ?    show tmux key bindings
```

The standard `Ctrl-b` prefix is intentionally preserved.
