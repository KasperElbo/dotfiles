# Printable keyboard cheat sheets

One A4 (1-2 page) printable cheat sheet per primary workstation profile,
organized by task (Launch, Navigate, Move, Workspaces, ...) rather than by
config-file order, so it works as an actual desk reference:

| Source | Profile |
|---|---|
| `fedora-kde.tex` | Fedora KDE (normal Plasma/Wayland workstation) |
| `fedora-sway.tex` | Fedora Sway (keyboard-first XMonad-like session) |
| `fedora-wsl.tex` | Fedora WSL (Windows desktop + Linux dev runtime) |
| `macos.tex` | Apple Silicon macOS (AeroSpace) |

`common-workflow.tex` is `\input` by every sheet above so the shared
terminal/editor workflow (Ghostty, Zsh, fzf, zoxide, tmux, LazyVim, Lazygit,
theme) is written once instead of duplicated four times in the LaTeX source;
each rendered PDF still includes it in full, since each sheet must be a
self-contained page at the machine. `cheatsheet.sty` holds the shared page
layout (A4 margins, a two-column task table, section headings) used by every
sheet. [`../keybindings.md`](../keybindings.md) is the same shared content
as an ordinary Markdown page, for reading on screen or linking from the
README instead of opening a PDF.

## Regenerating the PDFs

```bash
docs/cheatsheets/generate.sh              # build all four
docs/cheatsheets/generate.sh fedora-sway  # build just one
```

This requires a LaTeX toolchain (`latexmk` plus a normal TeX Live
installation --- `geometry`, `multicol`, `xcolor`, `booktabs`, `enumitem`,
and `needspace` are the only non-base packages used). On Fedora, the
repository's own optional LaTeX profile already provides this:

```bash
./scripts/install-latex.sh
```

or any other TeX Live install (`texlive-scheme-medium` or larger) that
includes `latexmk`.

**The rendered PDFs are intentionally not committed.** They regenerate
byte-for-byte from the tracked `.tex` source in this directory (the script
pins `SOURCE_DATE_EPOCH` so the embedded PDF timestamp/ID does not change
between runs on unchanged source), so there is no derived artifact that can
silently drift out of sync with it --- only the source in this directory is
the source of truth. Run `generate.sh` yourself whenever you want a PDF to
print or read; `git status` after running it should show nothing new, since
`.gitignore` excludes the build output.

## Keeping the sheets accurate

`tests/test-cheatsheet-bindings.sh` (run by `./scripts/test.sh`) greps the
tracked Sway, Waybar, and AeroSpace configuration for the specific bindings
these cheat sheets document (terminal/application launcher, focus/move,
workspace switching, the keyboard-layout toggle, and the Waybar layout
indicator) and fails if a documented binding no longer exists in the
config it claims to describe. It is deliberately not a LaTeX compile check
(that would require a LaTeX toolchain in every environment that runs
`./scripts/test.sh`) and it deliberately does not try to catch every
possible drift --- only the load-bearing bindings called out above.

When Sway, Waybar, or AeroSpace bindings change:

1. Update the relevant `\csrow{...}{...}` lines in `fedora-sway.tex` /
   `macos.tex` and the matching table in `../keybindings.md` if the shared
   section changed.
2. Update `tests/test-cheatsheet-bindings.sh` if a load-bearing binding it
   checks was intentionally renamed or removed.
3. Run `./docs/cheatsheets/generate.sh` and look at the result before
   committing --- `./scripts/test.sh` does not do this for you.
