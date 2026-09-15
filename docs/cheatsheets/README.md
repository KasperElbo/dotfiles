# Printable keyboard cheat sheets

One A4 (1-2 page) printable cheat sheet per primary workstation/lab profile,
organized by task (Launch, Navigate, Move, Workspaces, ...) rather than by
config-file order, so it works as an actual desk reference:

| Source | Profile | Page budget |
|---|---|---|
| `fedora-kde.tex` | Fedora KDE (normal Plasma/Wayland workstation) | 1 |
| `fedora-sway.tex` | Fedora Sway (keyboard-first XMonad-like session) | 2 |
| `fedora-wsl.tex` | Fedora WSL (Windows desktop + Linux dev runtime) | 1 |
| `macos.tex` | Apple Silicon macOS (AeroSpace) | 2 |
| `parrot-ctf.tex` | Parrot Security Edition CTF guest | 1 |

The two-page budgets belong to the sheets whose window-manager tables fill a
page on their own; the shared block then flows into the second page rather
than being forced there, so neither page is half empty. The budgets are
enforced, not aspirational: `verify.sh` fails a sheet that grows past its page
count, and also fails a last page carrying nothing but the footer.

`common-workflow.tex` is `\input` by every sheet so the shared terminal/editor
workflow (Ghostty, Zsh, fzf, zoxide, tmux, LazyVim, Lazygit, theme) is written
once instead of copied per sheet; each PDF still includes it in full, since a
sheet has to be self-contained at the machine. Its closing terminal line is
the one platform-dependent part: each sheet defines `\cstermlegend` before the
`\input`, so the WSL sheet does not print a `ghostty` command its runtime does
not have, and no sheet prints another platform's copy/paste keys.
`cheatsheet.sty` holds the shared page layout (A4 margins, a two-column task
table, section headings) used by every sheet.

The Parrot sheet is a reduced *profile*, not a reduced *shell*: the guest
stows the same `bin` and `zsh` packages and installs tmux, fzf, zoxide and
Lazygit, so it prints the shared shell, line-editing, fzf and tmux rows it
genuinely has. What it leaves out is the LazyVim keymap — the guest shares it,
and the sheet points at WhichKey instead — and the workstation-only editor
integrations it does not have at all. Both decisions are recorded per action
in `config/actions.tsv` and checked; see below.

These sheets are a **curated subset**, not a rendering of the full reference.
[`../reference/keybindings.md`](../reference/keybindings.md) is the larger
on-screen reference and covers more than any sheet does; a sheet leaves things
out on purpose to stay within its page budget. Neither is generated from the
other — that page's prose and this LaTeX are hand-written — but both are
checked against the same registry, `config/actions.tsv`, and that page's
complete action table *is* generated from it.

## Regenerating the PDFs

```bash
docs/cheatsheets/generate.sh              # build all five
docs/cheatsheets/generate.sh fedora-sway  # build just one
```

This requires a LaTeX toolchain (`latexmk` plus a normal TeX Live
installation --- `geometry`, `multicol`, `xcolor`, `booktabs`, `enumitem`,
and `needspace` are the only non-base packages used). On Fedora, the
repository's own optional LaTeX profile already provides this:

```bash
./platforms/fedora/scripts/install-latex.sh
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
sheets, and — when it does not, or not on all of them — why.
`scripts/validate-actions.py` checks every direction of that claim:

- an action marked `print=true` must appear on every sheet it names, with a
  binding *and* a description that still agree with the registry;
- every `\csrow` on a sheet must be claimed by a registry entry for that sheet;
- a sheet that documents an action in a sentence rather than a table row says
  so with a `% csprose: <action-id>` comment, and the registry says
  `sheet:prose` — a prose claim has to be deliberate on both sides;
- an action whose platform reaches a sheet it is *not* printed on must record
  why in `print_reason`, so a missing row is a decision rather than an
  oversight.

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
successful compile does not: the page budget above, a last page that carries
real content rather than an orphaned footer, A4 page size, no overfull box
wide enough to clip content, no undefined reference, and byte-identical output
across two builds from unchanged source.

## Keeping the sheets accurate

`tests/test-cheatsheet-bindings.sh` (run by `./scripts/test.sh`) takes the
Sway and AeroSpace bindings it checks *from the registry itself* rather than
re-typing them: it reads each `source_pattern` for those two configs, proves
the pattern still matches the config, and proves the sheet still prints the
matching registry `binding`. On top of that it asserts the claims no registry
row can express — that the KDE sheet calls `Meta+Alt+K` Plasma's own default
rather than a dotfiles binding, that the WSL sheet omits the layout toggle and
names Noctty, that the Parrot sheet stays a guest reference, and that
`../reference/keybindings.md` keeps pointing at each tool's own discovery
mechanism. It is deliberately not a LaTeX compile check (that would require a
LaTeX toolchain in every environment that runs `./scripts/test.sh`).

When Sway, Waybar, or AeroSpace bindings change:

1. Update `config/actions.tsv` first --- its `source_pattern` is what both
   `scripts/validate-actions.py` and the test above check against the config.
2. Update the matching `\csrow{...}{...}` lines in `fedora-sway.tex` /
   `macos.tex`, then run `./scripts/render-action-reference.py` so the
   generated table in `../reference/keybindings.md` follows.
3. Run `./docs/cheatsheets/generate.sh` and look at the result before
   committing --- `./scripts/test.sh` does not do this for you.
