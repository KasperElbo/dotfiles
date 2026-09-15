# Keyboard and workflow reference

This is the full on-screen reference for the day-to-day keyboard and tooling
workflow shared across every workstation profile. It documents what is
actually useful while working on the machine, not every upstream keybinding
each tool ships with.

The complete, exhaustive table below is generated from `config/actions.tsv`,
the canonical registry of every action this repository defines. Every binding
and command this repository defines is in that table and nowhere else on this
page: the prose around it is hand-written and covers only what a table cannot —
what to reach for, which tool's own help to prefer over any static list, and
what this repository deliberately does not configure.

It is deliberately larger than any printable sheet. The per-profile
[cheat sheets](../cheatsheets/) are a curated subset sized for one or two
printed A4 pages, written in their own LaTeX source (`common-workflow.tex`
holds the shared block each workstation sheet `\input`s). This page and that
source are separate artifacts with separate jobs: completeness here, a page
budget there.

Where this repository does not configure something, that is stated explicitly
below, so an upstream default is never confused for a dotfiles binding.

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

`zsh/.zshenv` and `zsh/.config/zsh/.zshrc` are the tracked startup files. The
aliases, functions and line-editing keys they define are in the generated table
below, under `zsh`.

`theme` accepts `latte`, `frappe`, `macchiato`, or `mocha`, plus an optional
`--preserve-wallpaper` flag. It updates tmux, Ghostty/Noctty, Starship,
bat, and Lazygit theming together, and the KDE/Sway desktop theme on profiles
that install a hook for it. The Zsh function that wraps it then re-execs this
shell so the new flavour takes effect here; the command itself does not restart
anything.

### Line editing

`Up`/`Down` use Zsh's `up-line-or-beginning-search` and
`down-line-or-beginning-search`: with text already typed they walk only the
history entries starting with it, and on an empty line they behave like plain
history navigation. `Ctrl+R` is untouched, and stays fzf's — prefix search and
fuzzy search are complementary, not alternatives.

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
default shell-integration bindings in the table below are therefore unmodified
upstream defaults, confirmed against this config rather than assumed.

## zoxide

`eval "$(zoxide init zsh)"` is the only configuration; both subcommands in the
table below are zoxide's own.

## tmux

`tmux/.tmux.conf` does not change the prefix, so it stays the tmux default
`Ctrl+B`. The tracked config is intentionally thin: 1-based window/pane
numbering, mouse support, a longer status refresh, and Catppuccin styling.
tmux is for persistence, long-running processes, and remote/SSH sessions ---
Ghostty remains the local tab/split/zoom manager, so tmux does not duplicate
that here. `Prefix ?` lists every key binding the running tmux actually has,
which is the list to trust; the table below carries the handful worth knowing
by heart.

## LazyVim / Neovim

`nvim-lazyvim/.config/nvim/lua/config/keymaps.lua` adds no repository keymaps
of its own. The LazyVim defaults in the table below are the ones worth knowing
by heart, verified against the pinned LazyVim commit in `lazy-lock.json`;
`Space` + WhichKey is the primary way to discover the rest.

Which LazyVim extras are enabled is decided by the `extras` list in
`nvim-lazyvim/.config/nvim/lua/config/profile.lua`, one per Neovim profile —
not by `lazyvim.json`, whose own `extras` array is deliberately empty so the
tracked profile is the only thing that selects them. `dap.core` is in the
workstation profile's list, and its bindings in that table were checked
against LazyVim's current `dap/core.lua`, not assumed.

### Markdown

The Markdown extra is enabled; Marksman, GFM rendering, and browser preview
are LazyVim's own. `markdown.lua` disables the extra's global
markdownlint-cli2/markdown-toc integrations (project-local formatting wins
instead) and adds `table-nvim` for table editing; its full set of row and
column operations sits under `<leader>m` in WhichKey and in the table below.

On Fedora WSL, `gx` and preview URLs route through `wsl-open` to the Windows
browser.

### LaTeX

LaTeX support is optional. `--latex` is a Fedora and Fedora WSL installer flag:
those platforms own the TeX distribution. On macOS TeX is externally managed
and `--latex` is rejected, but the bindings below work once you install MacTeX
or BasicTeX yourself. VimTeX owns compilation, PDF viewing,
and build-log errors; TexLab owns completion, navigation, diagnostics, and
formatting (its own build/ChkTeX-on-save are disabled to avoid duplicating
VimTeX). Bindings use the local leader `\`, shown under `\l` via WhichKey and
listed in the table below.

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
(`latte`, `frappe`, `macchiato`, `mocha`). It writes the shared state under
`~/.config/dotfiles/`, and everything themed here reads that one choice:
Ghostty/Noctty, tmux and `delta` — and so Git's own diffs — re-read it
directly; Starship, bat, Lazygit and fzf are selected from it when Zsh starts,
and Neovim reads `~/.config/dotfiles/theme` when it starts, so those three
groups follow in shells and editor instances opened afterwards.

Platform-specific hooks under `~/.config/dotfiles/theme-hooks.d/` extend it:
the Fedora hook additionally re-themes KDE/Sway/Waybar and the flavour-matched
wallpaper; the Fedora WSL hook updates Noctty's managed config through Windows
PowerShell. There is no macOS theme hook, so `theme` there only changes the
terminal/editor/CLI tooling above, not system appearance. Wallpaper and `--preserve-wallpaper` are
Fedora-desktop concepts: on Fedora WSL, macOS and the Parrot guest there is no
repository-managed wallpaper to preserve.

The shell re-exec belongs to the Zsh wrapper, not to the command; see
[which layer does what](../workflows/theming.md#which-layer-does-what).

<!-- BEGIN GENERATED ACTION REFERENCE -->

<!-- Generated from config/actions.tsv by scripts/render-action-reference.py.
     Do not edit between these markers; edit the registry and regenerate. -->

## Complete action reference

Every action this repository defines or deliberately puts in front of you: 137 entries, grouped by the platform they exist on.

**Origin** is the distinction that matters when something behaves unexpectedly.
`repository` means this repository binds it, and the `Source` column says where.
`upstream` means the tool ships it and installing that tool is all this
repository did — report those upstream, not here.

**Print** says whether the action is on a printable cheat sheet. The sheets are
curated to one or two A4 pages per profile, so `no` is a deliberate editorial
choice with a recorded reason, never an omission.

### Every platform

#### fzf

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Alt+C` | Fuzzy cd into a directory | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+T` | Fuzzy file selection | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+R` | Fuzzy history search | key | upstream | `base` | the tool's own help | yes | — |

#### lazygit

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `?` | Contextual key-binding help for the current panel | key | upstream | `base` | the tool's own help | yes | — |
| `lazygit` | Open Lazygit from any Git repository | command | upstream | `base` | the tool's own help | yes | — |

#### neovim

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `S-h/S-l` | Previous / next buffer | key | upstream | `base` | WhichKey | yes | — |
| `<lead>,` | Switch buffers | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ca` | Code action | key | upstream | `base` | WhichKey | yes | — |
| `<lead>db` | Toggle breakpoint | key | upstream | `base` | WhichKey | yes | — |
| `<lead>dc` | Start / continue debugging | key | upstream | `base` | WhichKey | yes | — |
| `<lead>du` | Toggle the debug UI | key | upstream | `base` | WhichKey | yes | — |
| `]d / [d` | Next / previous diagnostic | key | upstream | `base` | WhichKey | yes | — |
| `<lead>xx` | Diagnostics list (Trouble) | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ff` | Find files | key | upstream | `base` | WhichKey | yes | — |
| `<lead>cf` | Format buffer | key | upstream | `base` | WhichKey | yes | — |
| `gd / gr` | Go to definition / references | key | upstream | `base` | WhichKey | yes | — |
| `K` | Hover documentation | key | upstream | `base` | WhichKey | yes | — |
| `<lead>gg` | Open Lazygit | key | upstream | `base` | WhichKey | yes | — |
| `<lead>/` | Live grep | key | upstream | `base` | WhichKey | yes | — |
| `<lead>cr` | Rename symbol | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ft` | Floating terminal | key | upstream | `base` | WhichKey | yes | — |
| `Space` | WhichKey menu | key | upstream | `base` | WhichKey | yes | — |
| `<leader>td` | EasyDotnet: debug the nearest test | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<leader>tt` | EasyDotnet: run the tests in this file | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<leader>tr` | EasyDotnet: run the nearest test | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<localleader>ll` | VimTeX: compile continuously | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>le` | VimTeX: build errors | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>li` | VimTeX: project info | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lo` | VimTeX: compiler output | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lt` | VimTeX: document table of contents | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lv` | VimTeX: view the PDF / forward search | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<leader>md` | table-nvim: delete the column | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>m` | WhichKey group: markdown | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mC` | table-nvim: insert a column to the left | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mc` | table-nvim: insert a column to the right | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mr` | table-nvim: insert a row below | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mK` | table-nvim: insert a row above | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mt` | table-nvim: insert a table | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mh` | table-nvim: move the column left | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>ml` | table-nvim: move the column right | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mj` | table-nvim: move the row down | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mk` | table-nvim: move the row up | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<M-l>` | table-nvim: next table cell | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<M-h>` | table-nvim: previous table cell | key | repository | `markdown` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |

#### theme

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `theme <f>` | Switch the active Catppuccin flavour across the terminal, editor and CLI tools, plus the desktop where a hook is installed | command | repository | `base` | documentation only | yes | `bin/.local/bin/theme` |

#### tmux

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Prefix [` | Scroll / copy mode | key | upstream | `base` | the tool's own help | yes | — |
| `Prefix ?` | List every tmux key binding | key | upstream | `base` | the tool's own help | yes | — |
| `Prefix s` | Choose a session | key | upstream | `base` | the tool's own help | yes | — |
| `Prefix d` | Detach from the session | key | upstream | `base` | the tool's own help | yes | — |
| `tmux new -As X` | Create or attach session X | command | upstream | `base` | the tool's own help | yes | — |

#### zoxide

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `z name / zi` | Jump to a ranked directory, or pick one interactively | command | upstream | `base` | the tool's own help | yes | — |

#### zsh

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `cat` | bat, with syntax highlighting | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |
| `ls / ll / la` | eza: short / long with git status / all files | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |
| `tree` | eza --tree | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |
| `shell-integrations` | Report optional tooling this shell could not activate | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |
| `Tab` | Open and select from the completion menu | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `Delete` | Delete the character under the cursor | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `Up / Down` | History entries matching the typed prefix | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `#` | Start an interactive comment | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `Home / End` | Beginning / end of the command line | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `Ctrl+Left / Right` | Move one word backward / forward | key | repository | `base` | the tracked config | yes | `zsh/.config/zsh/.zshrc` |
| `tar A.tar.gz P...` | Create an archive, compression chosen from the suffix | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |
| `theme <flavour>` | Zsh wrapper that re-execs the shell after a successful or partial theme change | command | repository | `base` | documentation only | no | `zsh/.config/zsh/.zshrc` |
| `untar A.tar.gz` | Extract an archive | command | repository | `base` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |

### Fedora workstation

#### kde

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Meta+Alt+K` | Plasma's own Switch to Next Keyboard Layout shortcut | key | upstream | `kde` | the tool's own help | yes | — |

#### sway

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Super+Shift+V` | Clipboard history picker (cliphist + Fuzzel) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+H/J/K/L` | Focus left/down/up/right | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Space` | Toggle focus between tiling and floating | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+A` | Focus the parent container | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Alt+K` | Switch between the US and Danish keyboard layouts | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+P` | Open Fuzzel (application launcher) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Enter` | Open Ghostty | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+Space` | Toggle floating | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+B / Super+V` | Split horizontal / vertical | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+S / Super+W` | Stacking / tabbed layout | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+E` | Toggle split layout | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Bright Up/Down` | Adjust panel brightness by 5% (brightnessctl) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Mic Mute` | Toggle the default source (wpctl) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Play/Next/Prev` | Media control (playerctl) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Vol Up/Down/Mute` | Adjust or mute the default sink (wpctl) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+R` | Enter resize mode | mode | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+H/J/K/L` | Move the focused container left/down/up/right | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+N` | Dismiss the current notification (Mako) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+N` | Restore the last dismissed notification | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `H/J/K/L` | Resize mode: shrink width / grow height / shrink height / grow width | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Enter, Esc` | Resize mode: return to the default mode | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Shift+Print` | Save the whole output to ~/Pictures/Screenshots | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Print, Super+Shift+S` | Select a region and annotate it (sway-screenshot) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+E` | Exit-session confirmation (swaynag) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+X` | Lock the session (swaylock) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+R` | Reload the Sway configuration | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `sway-session-start` | Session wrapper Sway's desktop entry launches (environment, Waybar, wallpaper) | command | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.local/bin/sway-session-start` |
| `Super+F` | Toggle fullscreen | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+C` | Kill the focused window | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Ctrl+H/J/K/L` | Move through the wrapping 3x3 workspace grid (sway-workspace-grid) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+1..9` | Move the container to workspace 1-9 | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+1..9` | Switch to workspace 1-9 | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |

#### theme

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `theme <f> --preserve-wallpaper` | Change the Catppuccin flavour while keeping the current desktop wallpaper (Fedora desktop only) | command | repository | `base` | documentation only | yes | `bin/.local/bin/theme` |

#### waybar

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Click: volume module` | Open pavucontrol | click | repository | `sway` | the status bar itself | no | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |
| `Click: bluetooth module` | Open blueman-manager | click | repository | `sway` | the status bar itself | no | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |
| `Waybar layout click` | Switch between the US and Danish keyboard layouts | click | repository | `sway` | the status bar itself | yes | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |
| `Click: network module` | Open nm-connection-editor | click | repository | `sway` | the status bar itself | no | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |
| `power-profile-status` | Status module showing the active asusd/power-profiles-daemon profile | command | repository | `sway` | the status bar itself | no | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |

#### zsh

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `x-copy` | Copy standard input to the X11 clipboard inside an explicit Fedora VM guest | command | repository | `vm-guest` | documentation only | no | `platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh` |

### Fedora on WSL

#### noctty

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Ctrl+Shift+,` | Reload the Noctty configuration | key | upstream | `base` | the tool's own help | yes | — |

#### wsl-interop

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `wsl-copy` | Send standard input to the Windows clipboard | command | repository | `base` | documentation only | yes | `platforms/fedora-wsl/stow/interop/.local/bin/wsl-copy` |
| `wsl-open <url\|path> [...]` | Open existing Linux paths or supported URIs with their Windows handlers | command | repository | `base` | documentation only | yes | `platforms/fedora-wsl/stow/interop/.local/bin/wsl-open` |
| `wsl-paste` | Write the Windows clipboard to standard output | command | repository | `base` | documentation only | yes | `platforms/fedora-wsl/stow/interop/.local/bin/wsl-paste` |

### Apple Silicon macOS

#### aerospace

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Control+Option+Tab` | Focus the next display | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+Tab` | Move the focused window to the next display | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Cmd+Tab` | Move the whole workspace to the next display | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+H/J/K/L` | Focus left/down/up/right, across displays | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+Enter` | Open a new Ghostty window | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+S/W` | Vertical / horizontal accordion | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+Space` | Toggle floating/tiling | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+B/V` | Horizontal / vertical tiles | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+E` | Toggle horizontal/vertical tiles | key | repository | `base` | the tracked config | no | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+R` | Enter resize mode | mode | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+H/J/K/L` | Move the focused window left/down/up/right, across displays | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `H/J/K/L` | Resize mode: shrink or grow width and height | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Enter, Esc` | Resize mode: return to the main mode | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+R` | Reload the AeroSpace configuration | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+C` | Close the focused window | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+F` | Fullscreen within the current Space | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Cmd+H/J/K/L` | Move through the wrapping 3x3 workspace grid (aerospace-workspace-grid) | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Ctrl+Opt+Shift+1..9` | Move the focused window to workspace 1-9 | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |
| `Control+Option+1..9` | Switch to workspace 1-9 | key | repository | `base` | the tracked config | yes | `platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml` |

#### macos

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `pbcopy / pbpaste` | Pipe to and from the system clipboard | command | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+3/4/5` | Full / region / toolbar screenshot | key | upstream | `base` | the tool's own help | yes | — |
| `Command+Space` | Native Spotlight | key | upstream | `base` | the tool's own help | yes | — |

### Parrot Security Edition CTF guest

#### installer

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `verify.sh` | Validate the installed guest profile and its ownership boundary | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/scripts/verify.sh` |

#### zsh

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `hex-decode HEX` | Decode hexadecimal text | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh` |
| `hex-encode TEXT` | Encode text as hexadecimal with xxd | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh` |
| `exec zsh -l` | Start the installed login shell in the current terminal | command | upstream | `ctf-guest` | documentation only | yes | — |
| `unsetopt NOMATCH` | Unmatched glob-looking arguments pass through to CTF tools instead of raising NOMATCH | mode | repository | `ctf-guest` | documentation only | no | `platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh` |
| `rot13 TEXT` | Apply ROT13 | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh` |
| `x-copy` | Copy standard input to the X11 clipboard | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh` |

### Why an action is not on a printable sheet

31 of the 137 registered actions are deliberately kept off every sheet:

| Action | Reason |
|---|---|
| `aerospace.layout.toggle-split` | The Sway analogue of Super+E; AeroSpace's own layout keys above cover the same need and the sheet keeps its Layout block to four rows |
| `fedora.x-copy` | Only present inside the optional VM-guest profile; the workstation sheets would advertise a command most machines do not have |
| `nvim.dotnet.debug-nearest` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.dotnet.run-file` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.dotnet.run-nearest` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.latex.compile` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.errors` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.info` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.output` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.toc` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.view` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.markdown.delete-column` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.group` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.insert-column-left` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.insert-column-right` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.insert-row-down` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.insert-row-up` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.insert-table` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.move-column-left` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.move-column-right` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.move-row-down` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.move-row-up` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.next-cell` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `nvim.markdown.prev-cell` | Markdown table editing is filetype-scoped and fully exposed through WhichKey's markdown group |
| `parrot.noglob` | A shell option rather than an invocable action; the Parrot sheet explains the policy in prose |
| `sway.session.start` | Sway's desktop entry runs it at login; there is nothing for a user to invoke |
| `waybar.audio.click` | Discoverable by clicking the module it sits on |
| `waybar.bluetooth.click` | Discoverable by clicking the module it sits on |
| `waybar.network.click` | Discoverable by clicking the module it sits on; the sheet documents only the layout click, which has no other entry point |
| `waybar.power-profile.status` | A status display, not an action: there is nothing to invoke |
| `zsh.function.theme-reexec` | The same user-facing command as zsh.command.theme; the re-exec is an implementation layer, documented in the theming guide |

<!-- END GENERATED ACTION REFERENCE -->

## Profile cheat sheets

Each profile's printable cheat sheet adds only what is specific to that
desktop/runtime on top of everything above:

- [Fedora KDE](../cheatsheets/fedora-kde.tex)
- [Fedora Sway](../cheatsheets/fedora-sway.tex)
- [Fedora WSL](../cheatsheets/fedora-wsl.tex)
- [macOS (AeroSpace)](../cheatsheets/macos.tex)

See [`cheatsheets/README.md`](../cheatsheets/README.md) for how to render them
to PDF.
