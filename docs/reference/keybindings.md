# Keyboard and workflow reference

This is the full on-screen reference for the day-to-day keyboard and tooling
workflow shared across every workstation profile. It documents what is
actually useful while working on the machine, not every upstream keybinding
each tool ships with.

The complete, exhaustive table below is generated from `config/actions.tsv`,
the canonical registry of every action this repository defines. Every binding,
alias and command this repository defines lives in that one generated table and
nowhere else on this page. The prose around it is hand-written and covers only
what a table cannot: what to reach for, which tool's own help to prefer over any
static list, and what this repository deliberately does not configure. It does
not restate the table, because two hand-maintained copies of the same row is how
a reference starts lying.

It is deliberately larger than any printable sheet. The per-profile
[cheat sheets](../cheatsheets/) are a curated subset sized for one or two
printed A4 pages, written in their own LaTeX source (`common-workflow.tex`
holds the shared block every sheet `\input`s). This page and that source are
separate artifacts with separate jobs: completeness here, a page budget
there — but both are checked against `config/actions.tsv`, so neither can
quietly describe a binding the configuration no longer has.

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
| Noctty (Windows) | `noctty +list-keybinds` |
| Herdr (`--ai` profile) | `Ctrl+B ?` |
| KDE Plasma | System Settings → Shortcuts |
| Sway / Waybar / AeroSpace | The tracked config itself --- see the profile cheat sheet |

## Ghostty

`ghostty/.config/ghostty/shared.conf` (also loaded by Noctty on Windows) sets
no `keybind =` at all, so **every** Ghostty shortcut --- new tab/window,
splits, tab navigation, zoom/font sizing, config reload --- is an unmodified
upstream default. Ghostty is the local tab/split/zoom manager; tmux is
deliberately not used to duplicate that on the same machine.

Being an upstream default is not a reason to leave it off a desk reference, so
the ones worth knowing by heart are printed on the profile cheat sheets and
registered in `config/actions.tsv` with `origin=upstream` --- the column that
says this repository did not bind them. What *is* true is that the set differs
per platform, which is why no sheet prints another platform's: the two Fedora
sheets share Ghostty's Linux/GTK defaults through
`docs/cheatsheets/ghostty-linux-keys.tex`, the macOS sheet carries the Cmd
chords Ghostty uses there, and the WSL sheet carries Noctty's own --- mostly
Ghostty's non-macOS set, except that it splits with `Ctrl+Shift+\` and moves
between panes with `Alt+Arrow`.

The defaults also move between Ghostty versions, and both terminals are
installed rolling (Terra, Homebrew, a Windows download), so the discovery
command above --- not this page and not a sheet --- is the authority on what
the copy you are sitting in front of actually has.

Clipboard copy/paste use the platform's normal shortcut: `Ctrl+Shift+C/V` on
Linux/Wayland, `Cmd+C/V` on macOS.

## Zsh

`zsh/.zshenv` and `zsh/.config/zsh/.zshrc` are the tracked startup files.
Their aliases, functions and key bindings are in the generated table below,
under `zsh`. Typing a directory name on its own changes into it (`AUTO_CD`),
and `#` starts an interactive comment so a documented command can be pasted
with its notes intact.

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
history navigation. `Ctrl-R` keeps fzf's own binding — prefix search and
fuzzy search are complementary, not alternatives — but this repository does
give it a preview pane, so it is `upstream-configured` rather than untouched.

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

The shared `.zshrc` sources `fzf --zsh` and does not rebind any key, so
`Ctrl-T` and `Alt-C` are unmodified upstream defaults, confirmed against this
config rather than assumed. `Ctrl-R` is the exception: the key is fzf's, but
`FZF_CTRL_R_OPTS` gives it a bat-rendered preview pane, a height and a layout,
which is why the registry records it as `upstream-configured`.

## zoxide

`eval "$(zoxide init zsh)"` is the only configuration; `z` and `zi` are
zoxide's own subcommands.

## tmux

`tmux/.tmux.conf` does not change the prefix, so it stays the tmux default
`Ctrl+B`. The tracked config is intentionally thin: 1-based window/pane
numbering, mouse support, a longer status refresh, and Catppuccin styling.
tmux is for persistence, long-running processes, and remote/SSH sessions ---
Ghostty remains the local tab/split/zoom manager, so tmux does not duplicate
that here. `Prefix ?` lists every binding the running tmux actually has,
which is the list to trust; the table below carries the handful worth knowing
by heart.

## Herdr (optional `--ai` profile)

Herdr is installed only by `./install.sh --ai` (see
[the AI profile](../profiles/ai.md)), so it is the one tool on the sheets that
a default install does not have; its rows carry `profile=ai` in the registry.
Nothing here configures it, so every binding below is Herdr's own default, and
`Ctrl+B ?` inside a running Herdr prints the live set.

Its prefix is `Ctrl+B` — the same key tmux uses, and neither tool is
reconfigured to avoid the other. Run one inside the other and the inner
multiplexer never sees a prefix at all; the split this repository intends is
Herdr for agent panes and tmux for ordinary shell persistence, not one nested
in the other. Herdr is also mouse-native, so clicking and dragging panes, tabs
and split borders needs no keybinding.

## LazyVim / Neovim

`nvim-lazyvim/.config/nvim/lua/config/keymaps.lua` adds no repository keymaps
of its own, so almost everything in the table below is LazyVim's own default
(verified against the pinned LazyVim commit in `lazy-lock.json`). That is why
`Space` + WhichKey is the primary way to discover the rest: it reads the
keymap the running editor has, and this page cannot.

`<leader>cf` is the one shared exception. Conform's formatter map is extended
in `lua/plugins/formatting.lua` (CSharpier for C#, Prettier for Angular
templates, Ruff for Python), so the key is LazyVim's and the result is partly
ours.

Under LazyVim's own defaults is Vim's, and the sheets print a block of those
too --- `i`/`a`/`o`, `w`/`b`/`e`, `ciw`, `u`, `.`, `:%s/a/b/g` and the rest.
Nothing here binds them, which is exactly why they are worth printing: they
are the keys that still work in an `nvim --clean`, on a server this repository
has never touched. `:help index` is their complete list.

The LazyVim rows were taken from the commit pinned in `lazy-lock.json` rather
than from LazyVim's website, which documents whatever is current: `<leader>e`
is the Snacks explorer and `<leader>ff`/`<leader>/` are the Snacks picker
because `install_version` in `lazyvim.json` is 8, the version at which LazyVim
makes Snacks — not neo-tree and Telescope — the default for a fresh install.

The enabled LazyVim extras are listed in
`nvim-lazyvim/.config/nvim/lua/config/profile.lua`, per profile — not in
`lazyvim.json`, whose `extras` array is deliberately empty because this
repository selects them in Lua. The workstation profile enables `dap.core`,
whose bindings were checked against LazyVim's current `dap/core.lua`, not
assumed. The reduced `parrot-ctf` profile enables far fewer, and imports
`lua/ctf_plugins` instead of `lua/plugins`: the Markdown table editing, LaTeX
and .NET bindings below do not exist on that guest.

### Markdown

The Markdown extra is enabled; Marksman, GFM rendering, and browser preview
are LazyVim's own. `markdown.lua` disables the extra's global
markdownlint-cli2/markdown-toc integrations (project-local formatting wins
instead) and adds `table-nvim` for table editing. Its bindings are all under
`<leader>m`, which WhichKey shows as a `markdown` group, and they are in the
generated table below under the workstation platforms.

`gd` (follow an internal link through Marksman), `gx` (open the URL under the
cursor), `<leader>cp` (browser preview) and `<leader>um` (in-buffer rendering)
are the extra's own. On Fedora WSL, `gx` and preview URLs route through
`wsl-open` to the Windows browser.

### LaTeX

LaTeX support is optional. `--latex` is a Fedora and Fedora WSL installer flag:
those platforms own the TeX distribution. On macOS TeX is externally managed
and `--latex` is rejected, but the bindings below work once you install MacTeX
or BasicTeX yourself. VimTeX owns compilation, PDF viewing,
and build-log errors; TexLab owns completion, navigation, diagnostics, and
formatting (its own build/ChkTeX-on-save are disabled to avoid duplicating
VimTeX). Bindings use the local leader `\`, shown under `\l` via WhichKey, and
are in the generated table below; `<leader>cf` formats through TexLab and
`latexindent` like any other buffer.

`\lv` picks its viewer per platform: `wsl-open` on Fedora WSL and macOS's own
`open` (no SyncTeX) on macOS, both set by that platform's Neovim overlay. On
Fedora the shared `latex.lua` uses Okular when it is installed, for forward and
inverse SyncTeX, and falls back to `xdg-open` when it is not — which is what a
Sway machine gets, since `install-latex.sh` does not install Okular. See
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
groups follow in shells and editor instances opened afterwards. Ghostty picks a
changed flavour up on a full restart rather than a config reload.

Platform-specific hooks under `~/.config/dotfiles/theme-hooks.d/` extend it:
the Fedora hook additionally re-themes KDE/Sway/Waybar and the flavour-matched
wallpaper; the Fedora WSL hook updates Noctty's managed config through Windows
PowerShell. There is no macOS theme hook, so `theme` there only changes the
terminal/editor/CLI tooling above, not system appearance. Wallpaper and
`--preserve-wallpaper` are
Fedora-desktop concepts: on Fedora WSL, macOS and the Parrot guest there is no
repository-managed wallpaper to preserve.

The shell re-exec belongs to the Zsh wrapper, not to the command; see
[which layer does what](../workflows/theming.md#which-layer-does-what).

<!-- BEGIN GENERATED ACTION REFERENCE -->

<!-- Generated from config/actions.tsv by scripts/render-action-reference.py.
     Do not edit between these markers; edit the registry and regenerate. -->

## Complete action reference

Every action this repository defines or deliberately puts in front of you: 233 entries, grouped by the platform they exist on.

**Origin** is the distinction that matters when something behaves unexpectedly.
`repository` means this repository binds it, and the `Source` column says where.
`upstream` means the tool ships it and installing that tool is all this
repository did — report those upstream, not here. `upstream-configured` is the
middle case: the key is the tool's own, but this repository changed what it does,
so the `Source` column applies and a surprise may well be ours.

**Print** says whether the action is on a printable cheat sheet. The sheets are
curated to one or two A4 pages per profile, so `no` is a deliberate editorial
choice with a recorded reason, never an omission.

### Every platform

#### fzf

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Alt+C` | Fuzzy cd into a directory | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+T` | Fuzzy file selection | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+R` | Fuzzy history search | key | upstream-configured | `base` | the tool's own help | yes | `zsh/.config/zsh/.zshrc` |

#### lazygit

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `?` | Contextual key-binding help for the current panel | key | upstream | `base` | the tool's own help | yes | — |
| `lazygit` | Open Lazygit from any Git repository | command | upstream | `base` | the tool's own help | yes | — |

#### neovim

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `<lead>bd` | Close the buffer, keep the window | key | upstream | `base` | WhichKey | yes | — |
| `S-h/S-l` | Previous / next buffer | key | upstream | `base` | WhichKey | yes | — |
| `<lead>,` | Switch buffers | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ca` | Code action | key | upstream | `base` | WhichKey | yes | — |
| `<lead>db` | Toggle breakpoint | key | upstream | `base` | WhichKey | yes | — |
| `<lead>dc` | Start / continue debugging | key | upstream | `base` | WhichKey | yes | — |
| `<lead>du` | Toggle the debug UI | key | upstream | `base` | WhichKey | yes | — |
| `]d / [d` | Next / previous diagnostic | key | upstream | `base` | WhichKey | yes | — |
| `<lead>xx` | Diagnostics list (Trouble) | key | upstream | `base` | WhichKey | yes | — |
| `<lead>e` | File explorer (Snacks), rooted at the project | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ff` | Find files | key | upstream | `base` | WhichKey | yes | — |
| `s` | Flash: jump to any visible position | key | upstream | `base` | WhichKey | yes | — |
| `<lead>cf` | Format buffer | key | upstream-configured | `base` | WhichKey | yes | `nvim-lazyvim/.config/nvim/lua/plugins/formatting.lua` |
| `gd / gr` | Go to definition / references | key | upstream | `base` | WhichKey | yes | — |
| `K` | Hover documentation | key | upstream | `base` | WhichKey | yes | — |
| `<lead>sk` | Search every keymap | key | upstream | `base` | WhichKey | yes | — |
| `<lead>l` | Lazy: plugin manager | key | upstream | `base` | WhichKey | yes | — |
| `<lead>gg` | Open Lazygit | key | upstream | `base` | WhichKey | yes | — |
| `<lead>/` | Live grep | key | upstream | `base` | WhichKey | yes | — |
| `Alt+J / Alt+K` | Move the line (or selection) down / up | key | upstream | `base` | WhichKey | yes | — |
| `<lead>qq` | Quit all | key | upstream | `base` | WhichKey | yes | — |
| `<lead>fr` | Recent files | key | upstream | `base` | WhichKey | yes | — |
| `<lead>cr` | Rename symbol | key | upstream | `base` | WhichKey | yes | — |
| `Ctrl+S` | Save the file, from any mode | key | upstream | `base` | WhichKey | yes | — |
| `<lead>ft` | Floating terminal | key | upstream | `base` | WhichKey | yes | — |
| `Space` | WhichKey menu | key | upstream | `base` | WhichKey | yes | — |
| `<lead>wd` | Close the window | key | upstream | `base` | WhichKey | yes | — |
| `Ctrl+H/J/K/L` | Focus the window left/down/up/right | key | upstream | `base` | WhichKey | yes | — |
| `<lead>- / <lead>\|` | Split the window below / right | key | upstream | `base` | WhichKey | yes | — |
| `gg / G` | Top / bottom of the buffer | key | upstream | `base` | the tool's own help | yes | — |
| `ciw / diw` | Change / delete the word under the cursor | key | upstream | `base` | the tool's own help | yes | — |
| `gcc / gc + motion` | Toggle a comment on the line / over a motion | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+U / Ctrl+D` | Half a screen up / down | key | upstream | `base` | the tool's own help | yes | — |
| `i / a / o` | Insert before / after the cursor, open a line below | key | upstream | `base` | the tool's own help | yes | — |
| `0 / $` | Start / end of the line | key | upstream | `base` | the tool's own help | yes | — |
| `h j k l` | Move left / down / up / right | key | upstream | `base` | the tool's own help | yes | — |
| `Esc` | Leave insert mode, back to normal mode | key | upstream | `base` | the tool's own help | yes | — |
| `.` | Repeat the last change | key | upstream | `base` | the tool's own help | yes | — |
| `/pat, then n / N` | Search, then next / previous match | key | upstream | `base` | the tool's own help | yes | — |
| `:%s/a/b/g` | Replace a with b in the whole buffer | key | upstream | `base` | the tool's own help | yes | — |
| `u / Ctrl+R` | Undo / redo | key | upstream | `base` | the tool's own help | yes | — |
| `v / V / Ctrl+V` | Character / line / block visual mode | key | upstream | `base` | the tool's own help | yes | — |
| `w / b / e` | Next word / previous word / end of word | key | upstream | `base` | the tool's own help | yes | — |
| `:w / :q / :wq / :q!` | Write / quit / write and quit / quit discarding | key | upstream | `base` | the tool's own help | yes | — |
| `yy / dd / p` | Yank / cut / put a line | key | upstream | `base` | the tool's own help | yes | — |

#### theme

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `theme <f>` | Switch the active Catppuccin flavour across the terminal, editor and CLI tools, plus the desktop where a hook is installed | command | repository | `base` | documentation only | yes | `bin/.local/bin/theme` |

#### tmux

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Prefix [` | Scroll / copy mode | key | upstream | `base` | the tool's own help | yes | — |
| `Prefix ?` | List every tmux key binding | key | upstream | `base` | the tool's own help | yes | — |
| `Mouse scroll / click` | Scroll a pane's history and select panes and windows with the mouse | mouse | repository | `base` | the tool's own help | yes | `tmux/.tmux.conf` |
| `Prefix 1..9` | Windows and panes are numbered from 1, matching the digits on the keyboard | mode | repository | `base` | the tool's own help | no | `tmux/.tmux.conf` |
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
| `<directory>` | Typing a directory name on its own changes into it (AUTO_CD) | mode | repository | `base` | the tracked config | no | `zsh/.config/zsh/.zshrc` |

### Every workstation platform

#### herdr

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Ctrl+B [` | Copy mode | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B q` | Detach; the agents keep running | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B ?` | List every binding | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B h/j/k/l` | Focus the pane left/down/up/right | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B z / Ctrl+B x` | Zoom / close the focused pane | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B w / Ctrl+B g` | Workspace picker / goto picker | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B b` | Toggle the agent sidebar (blocked/working/done/idle) | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B v / Ctrl+B -` | Split the pane right / down | key | upstream | `ai` | the tool's own help | yes | — |
| `herdr` | Start or reattach the workspace; agents survive a detach | command | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B n / Ctrl+B p` | Next / previous tab | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B 1..9` | Jump to tab 1-9 | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B c` | New tab | key | upstream | `ai` | the tool's own help | yes | — |
| `Ctrl+B Shift+N` | New workspace | key | upstream | `ai` | the tool's own help | yes | — |

#### neovim

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `<leader>td` | EasyDotnet: debug the nearest test | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<leader>tt` | EasyDotnet: run the tests in this file | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<leader>tr` | EasyDotnet: run the nearest test | key | repository | `dotnet-debug` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/dotnet.lua` |
| `<localleader>ll` | VimTeX: compile continuously | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>le` | VimTeX: build errors | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>li` | VimTeX: project info | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lo` | VimTeX: compiler output | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lt` | VimTeX: document table of contents | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<localleader>lv` | VimTeX: view the PDF / forward search | key | repository | `latex` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/latex.lua` |
| `<leader>md` | table-nvim: delete the column | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>m` | WhichKey group: markdown | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mC` | table-nvim: insert a column to the left | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mc` | table-nvim: insert a column to the right | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mr` | table-nvim: insert a row below | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mK` | table-nvim: insert a row above | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mt` | table-nvim: insert a table | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mh` | table-nvim: move the column left | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>ml` | table-nvim: move the column right | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mj` | table-nvim: move the row down | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<leader>mk` | table-nvim: move the row up | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<M-l>` | table-nvim: next table cell | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |
| `<M-h>` | table-nvim: previous table cell | key | repository | `base` | WhichKey | no | `nvim-lazyvim/.config/nvim/lua/plugins/markdown.lua` |

#### zsh

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `cc` | Claude Code, started with permission prompts disabled | command | repository | `ai` | `shell-integrations` / `--help` | yes | `zsh/.config/zsh/.zshrc` |

### Fedora workstation

#### ghostty

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Ctrl+Shift+P` | Command palette | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+, / Ctrl+Shift+,` | Open / reload the configuration | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+C / V` | Copy / paste | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Plus / Minus / 0` | Grow / shrink / reset the font | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Enter` | Toggle fullscreen | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+Up / Down` | Jump to the previous / next shell prompt | key | upstream | `base` | the tool's own help | yes | — |
| `Shift+PgUp / PgDn` | Scroll the viewport a page | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+F` | Search the scrollback (Esc leaves) | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Alt+arrows` | Focus the split in that direction | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+O / E` | Split right / down | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+Enter` | Zoom the focused split | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Tab / Ctrl+Shift+Tab` | Next / previous tab | key | upstream | `base` | the tool's own help | yes | — |
| `Alt+1..8, Alt+9` | Go to tab 1-8, last tab | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+T / W` | New / close tab | key | upstream | `base` | the tool's own help | yes | — |

#### installer

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `verify.sh` | Validate the installed Fedora workstation profile and its capabilities | command | repository | `base` | documentation only | no | `platforms/fedora/scripts/verify.sh` |

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
| `cliphist store` | Clipboard watchers Sway starts for text and images, which are what the history picker lists | session | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+E` | Exit-session confirmation (swaynag) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `swayidle` | Idle watcher Sway starts: lock at 10 minutes, blank the outputs at 15, and lock before sleep | session | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+X` | Lock the session (swaylock) | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `mako` | Notification daemon Sway starts, configured from the tracked mako.conf | session | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.config/sway/config` |
| `lxqt-policykit-agent` | Authentication agent Sway starts, so a graphical privilege prompt has somewhere to appear | session | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Shift+R` | Reload the Sway configuration | key | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
| `sway-session-start` | Session wrapper Sway execs at startup: the sway-systemd session, a portal restart and XDG autostart | session | repository | `sway` | the tracked config | no | `platforms/fedora/stow/sway/.config/sway/config` |
| `Super+Drag / Right-drag` | Move a floating window with the left button held, resize it with the right | mouse | repository | `sway` | the tracked config | yes | `platforms/fedora/stow/sway/.config/sway/config` |
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
| `Waybar workspace scroll` | Deliberately disabled, so a stray scroll over the bar cannot change workspace | mouse | repository | `sway` | the status bar itself | no | `platforms/fedora/stow/waybar/.config/waybar/config.jsonc` |

#### zsh

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `x-copy` | Copy standard input to the X11 clipboard inside an explicit Fedora VM guest | command | repository | `vm-guest` | documentation only | no | `platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh` |

### Fedora on WSL

#### installer

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `verify.sh` | Validate the installed Fedora WSL profile and its Windows interoperability | command | repository | `base` | documentation only | no | `platforms/fedora-wsl/scripts/verify.sh` |

#### neovim

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `"+y / "+p` | Yank to and put from the Windows clipboard, through wsl-copy and wsl-paste | key | repository | `base` | documentation only | no | `platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua` |
| `gx` | Open the URL under the cursor, the Markdown preview and the built PDF with their Windows handler, through wsl-open | key | repository | `base` | documentation only | no | `platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua` |

#### noctty

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Ctrl+Shift+P` | Command palette | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+X` | Copy mode | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+C / V` | Copy / paste | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+= / Ctrl+-` | Increase / decrease the font size | key | upstream | `base` | the tool's own help | yes | — |
| `Alt+arrows` | Move between panes | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+,` | Reload the Noctty configuration | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+F` | Start a search | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+\ / E` | Split pane right / down | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Tab / Ctrl+Shift+Tab` | Next / previous tab | key | upstream | `base` | the tool's own help | yes | — |
| `Ctrl+Shift+T / W` | New / close tab | key | upstream | `base` | the tool's own help | yes | — |

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

#### ghostty

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `Cmd+K / Cmd+A` | Clear the screen / select all | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+P` | Command palette | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+, / Cmd+Shift+,` | Open / reload the configuration | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+C / Cmd+V` | Copy / paste | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Plus / Minus / 0` | Grow / shrink / reset the font | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Enter` | Toggle fullscreen | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+Up / Down` | Jump to the previous / next shell prompt | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+[ / Cmd+]` | Previous / next split | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Opt+arrows` | Focus the split in that direction | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+D / Cmd+Shift+D` | Split right / down | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+Enter` | Zoom the focused split | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+[ / ]` | Previous / next tab | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+1..8, Cmd+9` | Go to tab 1-8, last tab | key | upstream | `base` | the tool's own help | yes | — |
| `Cmd+T / Cmd+W` | New tab / close the focused surface | key | upstream | `base` | the tool's own help | yes | — |

#### installer

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `verify.sh` | Validate the installed macOS profile and its managed defaults | command | repository | `base` | documentation only | no | `platforms/macos/scripts/verify.sh` |

#### macos

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `pbcopy / pbpaste` | Pipe to and from the system clipboard | command | upstream | `base` | the tool's own help | yes | — |
| `Cmd+Shift+3/4/5` | Full / region / toolbar screenshot | key | upstream | `base` | the tool's own help | yes | — |
| `Command+Space` | Native Spotlight | key | upstream | `base` | the tool's own help | yes | — |

#### neovim

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `<localleader>lv` | VimTeX opens the built PDF with macOS's own open, which has no SyncTeX | key | repository | `latex` | WhichKey | no | `platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua` |

### Parrot Security Edition CTF guest

#### command-shims

| Binding | Action | Input | Origin | Profile | Discover via | Print | Source |
|---|---|---|---|---|---|---|---|
| `bat` | Debian's batcat under the name every other platform uses | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/command-shims/.local/bin/bat` |
| `fd` | Debian's fdfind under the name every other platform uses | command | repository | `ctf-guest` | documentation only | yes | `platforms/parrot-ctf/stow/command-shims/.local/bin/fd` |

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

44 of the 233 registered actions are deliberately kept off every sheet:

| Action | Reason |
|---|---|
| `aerospace.layout.toggle-split` | The Sway analogue of Super+E; AeroSpace's own layout keys above cover the same need and the sheet keeps its Layout block to four rows |
| `fedora-wsl.verify` | The workstation sheets are a desktop and shell reference; the platform guide is where an installer-time command belongs |
| `fedora.verify` | The workstation sheets are a desktop and shell reference; the platform guide is where an installer-time command belongs |
| `fedora.x-copy` | Only present inside the optional VM-guest profile; the workstation sheets would advertise a command most machines do not have |
| `macos.verify` | The workstation sheets are a desktop and shell reference; the platform guide is where an installer-time command belongs |
| `nvim.dotnet.debug-nearest` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.dotnet.run-file` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.dotnet.run-nearest` | Preserves LazyVim's own test keys in C# buffers, so it is discoverable exactly where a LazyVim user already looks |
| `nvim.latex.compile` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.errors` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.info` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.output` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.toc` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.latex.view` | LaTeX editing is an optional profile; the workstation sheets stay a desktop and shell reference |
| `nvim.macos.latex-view` | LaTeX editing is an optional profile, and this row records a platform viewer rather than a different key |
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
| `nvim.wsl.clipboard` | It gives Neovim's own clipboard registers a Windows provider rather than adding a key; the WSL sheet documents wsl-copy and wsl-paste |
| `nvim.wsl.open` | It re-routes Neovim's own gx and preview rather than adding a key; the WSL sheet documents wsl-open once, for every caller |
| `parrot.noglob` | A shell option rather than an invocable action; the Parrot sheet explains the policy in prose |
| `sway.session.clipboard-watch` | A background session service Sway starts itself; the history picker it fills is registered separately |
| `sway.session.idle` | A background session service Sway starts itself; the key that locks on demand is registered separately |
| `sway.session.notifications` | A background session service Sway starts itself; the keys that dismiss and restore a notification are registered separately |
| `sway.session.polkit` | A background session service Sway starts itself; there is nothing for a user to invoke |
| `sway.session.start` | Sway's own config execs it at session startup; there is nothing for a user to invoke |
| `tmux.option.numbering` | The numbering is visible in the status bar the moment tmux starts; the sheets' tmux block is for keys |
| `waybar.audio.click` | Discoverable by clicking the module it sits on |
| `waybar.bluetooth.click` | Discoverable by clicking the module it sits on |
| `waybar.network.click` | Discoverable by clicking the module it sits on; the sheet documents only the layout click, which has no other entry point |
| `waybar.power-profile.status` | A status display, not an action: there is nothing to invoke |
| `waybar.workspaces.scroll` | It records a suppressed default rather than an action: there is nothing to press |
| `zsh.function.theme-reexec` | The same user-facing command as zsh.command.theme; the re-exec is an implementation layer, documented in the theming guide |
| `zsh.option.auto-cd` | A shell option rather than an invocable action; every sheet's shell block lists the commands and keys this repository adds |

### Why a printed action is missing from a sheet it could appear on

These 46 actions are printed somewhere, but not on every sheet whose platform has them. The registry records why, and `scripts/validate-actions.py` refuses a silent omission:

| Action | Printed on | Reason |
|---|---|---|
| `lazygit.help` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: Lazygit is installed on the guest, but its Git workflow is the shared one and the sheet is a CTF operations reference |
| `lazygit.open` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: Lazygit is installed on the guest, but its Git workflow is the shared one and the sheet is a CTF operations reference |
| `lazyvim.buffer-close` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.buffer-cycle` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.buffers` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.code-action` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.dap-breakpoint` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.dap-continue` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.dap-ui` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.diagnostic-cycle` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.diagnostics` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.explorer` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.find-files` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.flash` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.format` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.goto` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.hover` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.keymaps` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.lazy` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.lazygit` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.live-grep` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.move-line` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.quit` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.recent-files` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.rename` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.save` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.terminal` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it |
| `lazyvim.window-close` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.window-focus` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `lazyvim.window-split` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest shares LazyVim's keymap, and that sheet points at WhichKey instead of reprinting it. |
| `nvim.default.buffer-ends` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.change-word` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.comment` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.half-page` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.insert` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.line-ends` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.motion` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.normal-mode` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.repeat` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.search` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.substitute` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.undo-redo` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.visual` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.word-motion` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.write-quit` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |
| `nvim.default.yank-put` | `fedora-kde`, `fedora-sway`, `fedora-wsl`, `macos` | Withheld from the Parrot sheet: the guest runs the same Neovim, and that sheet points at WhichKey rather than reprinting an editor keymap. |

<!-- END GENERATED ACTION REFERENCE -->

## Profile cheat sheets

Each profile's printable cheat sheet adds only what is specific to that
desktop/runtime on top of everything above:

- [Fedora KDE](../cheatsheets/fedora-kde.tex)
- [Fedora Sway](../cheatsheets/fedora-sway.tex)
- [Fedora WSL](../cheatsheets/fedora-wsl.tex)
- [macOS (AeroSpace)](../cheatsheets/macos.tex)
- [Parrot Security Edition CTF guest](../cheatsheets/parrot-ctf.tex)

See [`cheatsheets/README.md`](../cheatsheets/README.md) for how to render them
to PDF.
