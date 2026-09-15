# Catppuccin theming

The repository installs all four Catppuccin flavors and uses one local selector.

First-install default:

```text
macchiato
```

Accent where applicable:

```text
mauve
```

## Where a run's flavour comes from

An installer resolves the flavour in this order, and says which tier it used in
both the dry-run plan and the interactive confirmation:

| Source | Meaning |
|---|---|
| `explicit` | `--theme FLAVOUR` on this invocation |
| `existing` | the flavour this machine already has in `~/.config/dotfiles/theme` |
| `remembered` | the flavour in the last successful install's recorded selection |
| `default` | first install only |

So an ordinary rerun never resets a machine to Macchiato:

```bash
./install.sh --theme latte     # installs Latte
./install.sh                   # still Latte  (source: existing)
./install.sh --theme mocha     # now Mocha    (source: explicit)
```

`existing` is checked before `remembered` because it is what the machine is
actually wearing: `theme mocha` changes it without running an installer.
`remembered` then covers a machine whose theme state file has been lost.

The remembered value is the `theme` field of the structured selection the
install lifecycle records — there is no theme-specific state
file competing with it, and no stored command text is ever parsed. It is
validated against the current option manifest before use, so a record this
checkout cannot interpret falls through to the next tier instead of being
guessed at.

`./install.sh --rerun` therefore replays the remembered flavour like any other
remembered option, reconstructed as an explicit `--theme` by the shared
selection library:

```bash
./install.sh --rerun --dry-run
# Options:   --theme latte --no-kde --no-latex …
```

Only a *successful* install replaces the remembered configuration, so a failed
or cancelled run leaves the previous flavour as the rerun target.

## Applying a theme: named actions

`theme <flavour>` applies a set of mostly independent effects, each a named
action with its own error boundary:

- the shared state files (`theme`, `ghostty.conf`, `git-theme`,
  `tmux-theme.conf`) are **required** — if they cannot be written the command
  stops with status 1 and applies nothing else;
- every other action is independent. One failing action is named, does not stop
  the others, and leaves the command with status 3 and a summary of what
  applied and what did not.

```text
Catppuccin mocha was applied only partially.
Applied:
  - shared-state
  - tmux
Failed:
  - fedora:kde (exit 9)
```

An action that is deliberately not run is reported separately, so "not
installed here" stays distinct from "failed":

```text
Not applicable on this machine:
  - fedora:kde (the KDE capability was not installed)
```

The last run's records stay in `~/.local/state/dotfiles/theme-actions.log`.

## Which layer does what

`theme` is three layers, and it matters which one a given effect belongs to:

| Layer | What it is | What it does |
|---|---|---|
| `theme` command | `bin/.local/bin/theme`, on `PATH` as `~/.local/bin/theme` | Writes the shared state files, runs the installed platform hooks, and reports what applied |
| Platform theme hook | `~/.config/dotfiles/theme-hooks.d/*.sh`, stowed per platform | Applies the desktop half: KDE/Sway/Waybar/Fuzzel/Mako/swaylock and the wallpaper on Fedora, the Noctty bridge on Fedora WSL. macOS and the Parrot guest install no hook |
| Zsh `theme` function | `zsh/.config/zsh/.zshrc` | **Re-execs the shell** (`exec zsh`) after a successful or partially successful run, so this shell picks up the new `DOTFILES_THEME` and its fzf/bat/Lazygit/Starship selections |

The re-exec is the shell wrapper's doing, not the command's. Running
`command theme mocha`, or the binary from a non-Zsh shell, updates state and
desktop but leaves the calling shell on its old flavour until it restarts. The
wrapper re-execs on status 0 and on status 3 — a partially applied theme still
leaves this shell's own theming correct — and deliberately does not on any
other status, where the shared state was not written and restarting would only
hide the failure.

## Hooks only apply what is installed

A platform hook must never apply an identifier for assets that were never
installed. The Fedora hook asks the install lifecycle state whether the `kde`
capability was selected, and separately whether the Catppuccin KDE global theme
for the chosen flavour is actually present:

- installed with `--no-kde` → no KDE command runs at all, even if Plasma is
  present and even if KDE themes are left over from an earlier install;
- selected but assets missing (a machine that predates the capability record)
  → still skipped, and the Fedora verifier reports it;
- no recorded installation at all → the assets alone decide.

The Fedora verifier checks exactly what the installed capability owns: with
KDE selected it requires `kio-extras` and the global theme for the current
flavour; with `--no-kde` it requires neither, and warns rather than fails if
leftover KDE assets are present.

The Parrot CTF guest deliberately installs no desktop theme hooks: it is a
reduced lab profile, not a workstation, and parity is not a reason to give it
desktop theming it has no use for.

## Terminal restart requirements

Ghostty applies a changed `theme` only on a **full restart**; a configuration
reload does not change an already-set theme. Nothing in this repository claims
otherwise. On Fedora the hook still requests a reload (it is worth doing for
the rest of the configuration) and then says a restart is required; on a
profile with no hook of its own — macOS — the portable command prints the same
guidance. On Fedora WSL, Windows owns the terminal, so the Noctty bridge is
what changes the theme and no Ghostty guidance is printed at all.

## KDE

All four global themes are installed with:

- Mauve accent
- Classic window decoration
- Catppuccin cursor theme

The pinned upstream installer always applies a theme in its non-interactive
mode. The Fedora installer suppresses those intermediate apply calls while it
installs all four flavours, then the shared `theme` command applies the chosen
flavour and its matching wallpaper once as the final desktop state.

Known Plasma identifiers:

| Flavor | Global theme | Color scheme | Cursor |
|---|---|---|---|
| Latte | `Catppuccin-Latte-Mauve` | `CatppuccinLatteMauve` | `catppuccin-latte-mauve-cursors` |
| Frappé | `Catppuccin-Frappe-Mauve` | `CatppuccinFrappeMauve` | `catppuccin-frappe-mauve-cursors` |
| Macchiato | `Catppuccin-Macchiato-Mauve` | `CatppuccinMacchiatoMauve` | `catppuccin-macchiato-mauve-cursors` |
| Mocha | `Catppuccin-Mocha-Mauve` | `CatppuccinMochaMauve` | `catppuccin-mocha-mauve-cursors` |

## Ghostty

Ghostty's theme files exist only where the `ghostty` package is stowed —
that is, on a headed installation (`common/stow.sh` skips the `ghostty`
package entirely on a headless one). Where it applies, all four official
Ghostty theme files are tracked under:

```text
~/.config/ghostty/themes/
```

The tracked Ghostty configuration has Macchiato as a fallback and optionally includes:

```text
~/.config/dotfiles/ghostty.conf
```

## Neovim

Catppuccin is installed through `lazy.nvim`, because LazyVim itself uses `lazy.nvim`.

The configuration does **not** use `vim.pack`.

Available colorschemes:

```vim
:colorscheme catppuccin-latte
:colorscheme catppuccin-frappe
:colorscheme catppuccin-macchiato
:colorscheme catppuccin-mocha
```

Neovim reads the machine-local theme state on startup and checks it again on `FocusGained`.

## Starship

The prompt has two source files and four generated outputs:

```text
config/starship/prompt.toml                      common prompt and modules
config/starship/palettes/catppuccin-<flavour>.toml   one palette table each
        |
        v
starship/.config/starship/catppuccin-<flavour>.toml  tracked, stowed
```

`config/starship/prompt.toml` is the single source of truth for everything the
four flavours share. It deliberately contains **no** `palette = …` selection
and **no** `[palettes.*]` table — the generator refuses to run if it does, and
each generated file therefore ends up with exactly one palette selection and
exactly one matching palette table, instead of all four.

Regenerate after changing either source:

```bash
./scripts/update-starship-themes.sh
./scripts/update-starship-themes.sh --check       # CI drift gate
./scripts/update-starship-themes.sh --output-dir DIR
```

`--check` regenerates into a temporary directory, proves generation is
byte-identical when run twice, and compares the result with the tracked files.
It never writes to the working tree: a stale tracked file fails and is named,
rather than being silently fixed. `./scripts/lint.sh` runs it, so a source
change committed without its regenerated outputs fails CI.

The shell selects one generated file using `STARSHIP_CONFIG`; that contract is
unchanged:

```zsh
export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/catppuccin-${DOTFILES_THEME}.toml"
```

The current prompt is based on Starship's Catppuccin Powerline preset, with:

- `.NET` added to the runtime section
- the command prompt on a second line
- command-duration notifications currently enabled
- the previous command's exit status after a failure

The Powerline layout may be simplified later.

### Failed-command exit status

The `[status]` module renders the **exact** numeric exit code, and only after a
failure:

```text
 …   01:42   in 2s ✘ 130
❯
```

`success_symbol` is empty, so Starship skips the module entirely on status `0`
and a successful prompt stays clean. `map_symbol` stays off so `126`, `127` and
`130` remain distinguishable numbers rather than one shared glyph. The red
error prompt character is unchanged, and the segment sits between
`$cmd_duration` and the line break, so the layout is the same whether or not a
duration is shown.

## fzf

All four official Catppuccin fzf snippets are tracked.

Zsh selects:

```text
catppuccin-fzf-${DOTFILES_THEME}.sh
```

The `Ctrl-R` configuration adds:

- reverse layout
- border
- command preview
- Bat syntax highlighting in the preview

## Bat

On Fedora, Fedora WSL, and macOS, Bat uses its packaged Catppuccin themes.
On the Parrot CTF guest, the packaged `bat` does not ship those syntaxes, so
`platforms/parrot-ctf/scripts/install-terminal.sh` downloads and verifies
(against pinned SHA-256 hashes) the four upstream Catppuccin theme files
itself, into `~/.config/bat/themes/`, so Git paging never silently falls back
without them.

The active flavor is selected using `BAT_THEME`.

## Delta

The official Catppuccin Delta configuration is tracked as a Git config fragment.

The active feature is provided by:

```text
~/.config/dotfiles/git-theme
```

## Lazygit

The functional Lazygit configuration remains separate from theme configuration.

The official mergeable Catppuccin theme files are tracked for all four flavors.

Zsh sets `LG_CONFIG_FILE` to merge the normal config and selected theme.

## tmux

Catppuccin's tmux plugin is **not vendored inside the dotfiles repository**.

It is installed to:

```text
~/.local/share/tmux/plugins/catppuccin
```

by:

```bash
./scripts/install-tmux-theme.sh
```

## Sway desktop

On Fedora, a platform hook makes the portable `theme` command also update Sway,
Waybar, Fuzzel, Mako, swaylock, the flavour-matched wallpaper, and the pointer
cursor theme. A running Sway session is reloaded automatically; new Fuzzel
invocations read the new generated configuration. Ghostty is reloaded through
its systemd user service when active, or directly with Ghostty's `SIGUSR2`
reload signal when launched from Sway. When a Sway session is actually
running, KDE desktop integration is skipped entirely, since Plasma's DBus
interface has nothing to talk to under Sway.

The generated Sway configuration sets `seat * xcursor_theme` to the
flavour-matched Catppuccin cursor theme. Cursor theme files are only
installed by the optional KDE profile's `install-kde-theme.sh`
(see [KDE](#kde)); on a Sway-only install (`./install.sh --sway` without
`--kde`), the directive references a theme that is not present on disk and
the pointer falls back to the system default.

Pass `--preserve-wallpaper` to keep the current KDE or Sway desktop wallpaper
while applying those theme changes. KDE's lock screen and Swaylock remain
flavour-controlled.

The four tracked 3840x2160 wallpapers form a flavour-matched tropical-island
day-to-night cycle adapted from the MIT-licensed Catppuccin wallpaper
collection. They are shared Fedora desktop theme assets used by both KDE and
Sway. Swaylock uses a separately tracked blurred and darkened derivative of the
active wallpaper. The exact upstream revision and license are recorded beside
the assets and in `LICENSES/Catppuccin.txt`.

---

## Updating Starship themes

Edit only the sources:

```text
config/starship/prompt.toml                          common prompt/modules
config/starship/palettes/catppuccin-<flavour>.toml   one Catppuccin palette
```

Then regenerate:

```bash
./scripts/update-starship-themes.sh
```

Never hand-edit a generated `starship/.config/starship/catppuccin-*.toml`:
`./scripts/lint.sh` runs `./scripts/update-starship-themes.sh --check`, which
regenerates from source into a temporary directory and fails CI when a tracked
output does not match byte for byte.

The generated flavor configs are also tracked so a clone can be used without running generation first.
