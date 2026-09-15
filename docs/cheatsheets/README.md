# Printable keyboard cheat sheets

One A4 (1-2 page) printable cheat sheet per primary workstation/lab profile,
organized by task (Launch, Navigate, Move, Workspaces, ...) rather than by
config-file order, so it works as an actual desk reference:

| Source | Profile | Page budget |
|---|---|---|
| `fedora-kde.tex` | Fedora KDE (normal Plasma/Wayland workstation) | 1 |
| `fedora-sway.tex` | Fedora Sway (keyboard-first XMonad-like session) | 2 |
| `fedora-wsl.tex` | Fedora WSL (Windows desktop + Linux dev runtime) | 2 |
| `macos.tex` | Apple Silicon macOS (AeroSpace) | 2 |
| `parrot-ctf.tex` | Parrot Security Edition CTF guest | 1 |

The budgets are enforced, not aspirational: `verify.sh` fails a sheet that
grows past its page count. The reduced Parrot guest gets a real sheet rather
than an excuse — a one-page operations reference covering its CTF helpers,
globbing policy, ownership boundary and validation command — because those are
exactly the things that differ from every other profile.

`common-workflow.tex` is `\input` by the four workstation sheets so the shared
terminal/editor workflow (Ghostty, Zsh, fzf, zoxide, tmux, LazyVim, Lazygit,
theme) is written once instead of duplicated four times in the LaTeX source;
each workstation PDF still includes it in full, since each sheet must be a
self-contained page at the machine. `cheatsheet.sty` holds the shared page
layout (A4 margins, a two-column task table, section headings) used by every
sheet. The Parrot sheet is deliberately reduced and does not advertise
workstation-only LazyVim integrations.

These sheets are a **curated subset**, not a rendering of the full reference.
[`../reference/keybindings.md`](../reference/keybindings.md) is the larger
on-screen reference and covers more than any sheet does; a sheet leaves things
out on purpose to stay within its page budget. The two are separate artifacts
with separate sources — nothing here is generated from that page, and nothing
there is generated from `common-workflow.tex`.

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

## The sheets are curated, and that is enforced

`config/actions.tsv` is the canonical registry of every action this repository
defines. Each entry records whether it belongs on a printable sheet, which
sheets, and — when it does not — why. `scripts/validate-actions.py` checks both
directions:

- an action marked `print=true` must actually appear on every sheet it names;
- every `\csrow` on a sheet must be claimed by a registry entry for that sheet.

The second direction is what keeps a shared block honest. A sheet cannot
advertise a Fedora-only flag on macOS, or call the WSL terminal Ghostty,
without a registry entry saying it should — and the registry knows which
platform each action exists on.

Completeness belongs to
[`../reference/keybindings.md`](../reference/keybindings.md), whose action
table is generated from the same registry and contains everything, including
every `print=false` entry. These sheets deliberately contain less.

## Verifying a sheet is still printable

```bash
docs/cheatsheets/verify.sh              # every sheet
docs/cheatsheets/verify.sh fedora-sway  # just one
```

CI runs this on every pull request. It compiles each sheet, then checks what a
successful compile does not: the page budget above, A4 page size, no overfull
box wide enough to clip content, no undefined reference, and byte-identical
output across two builds from unchanged source.

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
   `macos.tex` and the matching table in `../reference/keybindings.md` if the shared
   section changed.
2. Update `tests/test-cheatsheet-bindings.sh` if a load-bearing binding it
   checks was intentionally renamed or removed.
3. Run `./docs/cheatsheets/generate.sh` and look at the result before
   committing --- `./scripts/test.sh` does not do this for you.
