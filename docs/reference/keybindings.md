# Keyboard and workflow reference

This is the full on-screen reference for the day-to-day keyboard and tooling
workflow shared across every workstation profile. It documents what is
actually useful while working on the machine, not every upstream keybinding
each tool ships with.

It is deliberately larger than any printable sheet. The per-profile
[cheat sheets](../cheatsheets/) are a curated subset sized for one or two
printed A4 pages, written in their own LaTeX source (`common-workflow.tex`
holds the shared block each workstation sheet `\input`s). This page and that
source are separate artifacts with separate jobs: completeness here, a page
budget there.

Every binding below is checked against the tracked configuration at the time
this page was last updated, not reconstructed from memory or old discussion.
Where this repository does not configure something, that is stated
explicitly so an upstream default is never confused for a dotfiles binding.

## Discover first

The fastest way to keep this page from going stale is to prefer each tool's
own built-in discovery mechanism over a static list:

| Tool | Discovery |
|---|---|
| LazyVim / Neovim | Press `Space` and read WhichKey |
| Lazygit | Press `?` inside any panel |
| tmux | `<prefix> ?` (prefix is `Ctrl+B`, unmodified) |
| Ghostty | `ghostty +list-keybinds --default` |
| KDE Plasma | System Settings → Shortcuts |
| Sway / Waybar / AeroSpace | The tracked config itself --- see the profile cheat sheet |

## Ghostty

`ghostty/.config/ghostty/shared.conf` (also loaded by Noctty on Windows) sets
no `keybind =` at all, so **every** Ghostty shortcut --- new tab/window,
splits, tab navigation, zoom/font sizing, config reload --- is an unmodified
upstream default. It varies by platform (Linux GTK vs. macOS) and Ghostty
version, so run the discovery command above rather than trusting a hardcoded
list. Ghostty is the local tab/split/zoom manager; tmux is deliberately not
used to duplicate that on the same machine.

Clipboard copy/paste use the platform's normal shortcut: `Ctrl+Shift+C/V` on
Linux/Wayland, `Cmd+C/V` on macOS.

## Zsh

`zsh/.zshenv` and `zsh/.config/zsh/.zshrc` are the tracked startup files.
Repository-defined aliases and functions that matter day to day:

| Command | Action |
|---|---|
| `ls` / `ll` / `la` | `eza` (short / long with git status / all files) |
| `tree` | `eza --tree` |
| `cat` | `bat` (syntax-highlighted) |
| `theme <flavour>` | switch the active Catppuccin flavour |
| `tar <archive> <path>…` | create an archive, compression chosen from the suffix |
| `untar <archive>` | extract an archive |
| `shell-integrations` | report optional tooling this shell could not activate |

`theme` accepts `latte`, `frappe`, `macchiato`, or `mocha`, plus an optional
`--preserve-wallpaper` flag. It updates tmux, Ghostty/Noctty, Starship,
bat, and Lazygit theming together, and the KDE/Sway desktop theme on profiles
that install a hook for it. The Zsh function that wraps it then re-execs this
shell so the new flavour takes effect here; the command itself does not restart
anything.

### Line editing

| Key | Action |
|---|---|
| `Up` / `Down` | previous/next history entry matching the current prefix |
| `Ctrl-R` | fuzzy-search command history with fzf |
| `Tab` | open/select from the Zsh completion menu |
| `Home` / `End` | beginning/end of the command line |
| `Delete` | delete the character under the cursor |
| `Ctrl+Left` / `Ctrl+Right` | move one word backward/forward |
| `#` | starts an interactive comment |

`Up`/`Down` use Zsh's `up-line-or-beginning-search` and
`down-line-or-beginning-search`: with text already typed they walk only the
history entries starting with it, and on an empty line they behave like plain
history navigation. `Ctrl-R` is untouched — prefix search and fzf's fuzzy
search are complementary, not alternatives.

Each of these keys is bound to the sequence `terminfo` reports **and** to the
documented xterm, application-cursor and vt220/rxvt fallbacks, because the
supported terminals do not agree on which mode is active when the line editor
starts:

| Key | terminfo | Fallbacks also bound |
|---|---|---|
| Home | `khome` | `\e[H`, `\eOH`, `\e[1~`, `\e[7~` |
| End | `kend` | `\e[F`, `\eOF`, `\e[4~`, `\e[8~` |
| Delete | `kdch1` | `\e[3~` |
| Ctrl+Left | `kLFT5` | `\e[1;5D`, `\eOd`, `\e[5D` |
| Ctrl+Right | `kRIT5` | `\e[1;5C`, `\eOc`, `\e[5C` |
| Up | `kcuu1` | `\e[A`, `\eOA` |
| Down | `kcud1` | `\e[B`, `\eOB` |

`\eOD` and `\eOC` are deliberately **not** bound to word motion: in
application-cursor mode those are plain `Left` and `Right`, which must keep
moving by a single character.

`tests/test-shell-startup.sh` asserts every one of these bindings by asking a
real `zsh` what each sequence resolves to, under `xterm-256color`,
`xterm-ghostty`, `screen-256color`, `tmux-256color`, `linux` and an unknown
`TERM`.

### Archive helpers

`tar` is a Zsh function, not an alias, so the native CLI is never shadowed:

```zsh
tar archive.tar.gz path...   # create (shorthand)
untar archive.tar.gz         # extract
tar -tf archive.tar.gz       # native tar, unchanged
tar -xf archive.tar.gz       # native tar, unchanged
tar --help                   # native tar, unchanged
command tar ...              # always the native tar
```

The shorthand applies only when the first argument is not an option *and*
carries a known archive suffix (`.tar`, `.tar.gz`/`.tgz`, `.tar.xz`/`.txz`,
`.tar.bz2`/`.tbz2`, `.tar.zst`/`.tzst`, and a few older forms). It then calls
`command tar -caf`, which picks the compressor from the suffix. `untar` calls
`command tar -xf`, which detects compression on its own.

### PATH and optional tooling

`.zshenv` marks Zsh's tied `path`/`PATH` pair unique (`typeset -gU path
PATH`). Sourcing `.zshenv` or `.zshrc` again — as `exec zsh`, a nested shell,
or `mise`/`opam` activation does — therefore cannot grow `PATH`. Zsh keeps the
*first* occurrence of a duplicate, so deliberate precedence is preserved and
nothing is sorted or reordered; the macOS rule that Homebrew's coreutils
`gnubin` stays last, behind Apple's own tools, is unaffected.

zoxide, fzf, mise and Starship are initialized only when they are installed. A
machine missing one gets that feature disabled and nothing else: the shell
still starts, and startup stays silent. Run `shell-integrations` to see what is
missing and what it costs.

`./scripts/benchmark-shell-startup.sh` measures interactive (`.zshenv` +
`.zshrc`) and non-interactive (`.zshenv` only) startup. It is a manual tool,
not part of `./scripts/test.sh`, because wall-clock timing is machine- and
load-dependent.

## fzf

The shared `.zshrc` sources `fzf --zsh` and only sets
`FZF_CTRL_R_OPTS` (a preview pane); it does not rebind any key. The three
default shell integration bindings are therefore unmodified upstream
defaults, confirmed against this config rather than assumed:

| Key | Action |
|---|---|
| `Ctrl-R` | fuzzy history search |
| `Ctrl-T` | fuzzy file selection |
| `Alt-C` | fuzzy `cd` into a directory |

## zoxide

`eval "$(zoxide init zsh)"` is the only configuration; both subcommands are
zoxide's own:

| Command | Action |
|---|---|
| `z name` | jump to a ranked directory matching `name` |
| `zi` | interactive directory picker |

## tmux

`tmux/.tmux.conf` does not change the prefix, so it stays the tmux default
`Ctrl+B`. The tracked config is intentionally thin: 1-based window/pane
numbering, mouse support, a longer status refresh, and Catppuccin styling.
tmux is for persistence, long-running processes, and remote/SSH sessions ---
Ghostty remains the local tab/split/zoom manager, so tmux does not duplicate
that here.

| Command / key | Action |
|---|---|
| `tmux new -As NAME` | create or attach a session |
| `tmux ls` | list sessions |
| `Prefix d` | detach |
| `Prefix s` | choose session |
| `Prefix [` | scroll/copy mode |
| `Prefix ?` | list every current key binding |

## LazyVim / Neovim

`nvim-lazyvim/.config/nvim/lua/config/keymaps.lua` adds no repository keymaps
of its own; the bindings below are LazyVim's own defaults (verified against
the pinned LazyVim commit in `lazy-lock.json`), which is why `Space` +
WhichKey is the primary way to discover the rest.

| Key | Action |
|---|---|
| `Space` | WhichKey menu |
| `<leader>ff` | find files |
| `<leader>/` | live grep |
| `<leader>,` | buffers |
| `Shift+H` / `Shift+L` | previous/next buffer |
| `gd` / `gr` | go to definition / references |
| `K` | hover docs |
| `<leader>ca` | code action |
| `<leader>cr` | rename symbol |
| `<leader>cf` | format buffer |
| `]d` / `[d` | next/previous diagnostic |
| `<leader>xx` | diagnostics list (Trouble) |
| `<leader>db` | toggle breakpoint (nvim-dap) |
| `<leader>dc` | start/continue debugging |
| `<leader>du` | toggle the debug UI |
| `<leader>ft` | floating terminal |
| `<leader>gg` | Lazygit |

The `dap.core` extra is enabled (see `lazyvim.json`); its bindings above were
checked against LazyVim's current `dap/core.lua`, not assumed.

### Markdown

The Markdown extra is enabled; Marksman, GFM rendering, and browser preview
are LazyVim's own. `markdown.lua` disables the extra's global
markdownlint-cli2/markdown-toc integrations (project-local formatting wins
instead) and adds `table-nvim` for table editing:

| Key | Action |
|---|---|
| `gd` | follow an internal link/heading through Marksman |
| `gx` | open the URL under the cursor |
| `<leader>cp` | toggle the live browser preview |
| `<leader>um` | toggle rendered Markdown in-buffer |
| `<leader>mt` | insert a GFM table |
| `Alt-l` / `Alt-h` | next/previous table cell |
| `<leader>mr` | insert a table row below |
| `<leader>mc` | insert a table column to the right |

The remaining row/column operations are under `<leader>m` via WhichKey. On
Fedora WSL, `gx` and preview URLs route through `wsl-open` to the Windows
browser.

### LaTeX

LaTeX support is optional. `--latex` is a Fedora and Fedora WSL installer flag:
those platforms own the TeX distribution. On macOS TeX is externally managed
and `--latex` is rejected, but the bindings below work once you install MacTeX
or BasicTeX yourself. VimTeX owns compilation, PDF viewing,
and build-log errors; TexLab owns completion, navigation, diagnostics, and
formatting (its own build/ChkTeX-on-save are disabled to avoid duplicating
VimTeX). Bindings use the local leader `\`, shown under `\l` via WhichKey:

| Key | Command | Action |
|---|---|---|
| `\ll` | `:VimtexCompile` | start/stop continuous `latexmk` |
| `\lv` | `:VimtexView` | open PDF, forward-search to cursor |
| `\le` | `:VimtexErrors` | toggle parsed errors (quickfix) |
| `\lo` | `:VimtexCompileOutput` | raw compiler output |
| `\lt` | `:VimtexTocOpen` | document table of contents |
| `\li` | `:VimtexInfo` | detected main file/compiler/viewer |
| `<leader>cf` | LazyVim format | format via TexLab + `latexindent` |

`\lv` uses Okular (forward/inverse SyncTeX) on Fedora KDE, `wsl-open` on
Fedora WSL, and macOS's `open` (no SyncTeX) elsewhere. See
[the LaTeX guide](../workflows/latex.md) for the full editing-workflow writeup.

## Lazygit

`lazygit/.config/lazygit/config.yml` only wires up `delta` as the diff
renderer; every keybinding is Lazygit's own. Open it with `lazygit` from any
Git repository, or `<leader>gg` inside LazyVim, then press `?` in any panel
for the current, contextual key-binding list --- Lazygit's own keymap
already changes between panels and versions, so this page does not attempt
to reproduce it.

## Theme command

`theme <flavour> [--preserve-wallpaper]` (`bin/.local/bin/theme`) is the
single portable command for switching the active Catppuccin flavour
(`latte`, `frappe`, `macchiato`, `mocha`) across tmux, Ghostty/Noctty,
Starship, bat, and Lazygit. Platform-specific hooks under
`~/.config/dotfiles/theme-hooks.d/` extend it: the Fedora hook additionally
re-themes KDE/Sway/Waybar and the flavour-matched wallpaper; the Fedora WSL
hook updates Noctty's managed config through Windows PowerShell. There is no
macOS theme hook, so `theme` there only changes the terminal/editor/CLI tooling
above, not system appearance. Wallpaper and `--preserve-wallpaper` are
Fedora-desktop concepts: on Fedora WSL, macOS and the Parrot guest there is no
repository-managed wallpaper to preserve.

The shell re-exec belongs to the Zsh wrapper, not to the command; see
[which layer does what](../workflows/theming.md#which-layer-does-what).

## Profile cheat sheets

Each profile's printable cheat sheet adds only what is specific to that
desktop/runtime on top of everything above:

- [Fedora KDE](../cheatsheets/fedora-kde.tex)
- [Fedora Sway](../cheatsheets/fedora-sway.tex)
- [Fedora WSL](../cheatsheets/fedora-wsl.tex)
- [macOS (AeroSpace)](../cheatsheets/macos.tex)

See [`cheatsheets/README.md`](../cheatsheets/README.md) for how to render them
to PDF.
