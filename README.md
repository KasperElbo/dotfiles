# Fedora Development Dotfiles

Opinionated, reproducible dotfiles for a keyboard-driven development workstation built around:

- Fedora
- KDE Plasma / Wayland
- Ghostty
- Zsh
- Neovim + LazyVim
- tmux
- Git + GitHub CLI + Lazygit
- mise-managed language runtimes
- Catppuccin across the desktop, terminal, editor, and CLI tools

The configuration is intended to stay close to upstream defaults. Custom behavior is added only where it solves a concrete workflow problem.

The current default Catppuccin flavor is **Macchiato** with the **Mauve** accent.

## Design principles

1. **Use the native package manager for machine-level tools.** Fedora/DNF owns operating-system and desktop-integrated tools.
2. **Use mise for language runtimes and portable developer CLIs.**
3. **Use Mason only for Neovim-specific tooling.**
4. **Keep project tooling in the project.** CSharpier, Prettier, ESLint, `dotnet-ef`, TypeScript, etc. should normally be declared by the repository that uses them.
5. **Keep shared configuration tracked and user-specific state local.**
6. **Prefer upstream workflows over custom glue.**

---

# Supported environment

This configuration has been developed and tested on:

- Fedora 44
- KDE Plasma on Wayland
- Zsh
- Ghostty
- Neovim 0.12+
- GNU Stow

The scripts currently assume a Fedora/DNF system.

---

# Quick start

Clone the repository. `~/src/dotfiles` is the conventional location used during development, but the scripts resolve the repository root dynamically.

```bash
mkdir -p ~/src
git clone <REPOSITORY_URL> ~/src/dotfiles
cd ~/src/dotfiles
```

Inspect the installation plan before making changes:

```bash
./install.sh --dry-run
```

Install using the defaults:

```bash
./install.sh
```

A fully non-interactive example:

```bash
./install.sh \
  --theme macchiato \
  --kde \
  --latex \
  --non-interactive
```

A minimal non-KDE installation:

```bash
./install.sh \
  --theme mocha \
  --no-kde \
  --no-latex \
  --non-interactive
```

## Installer options

```text
--theme FLAVOUR    latte | frappe | macchiato | mocha
                   default: macchiato

--kde              install Catppuccin KDE integration
--no-kde           skip KDE integration

--latex            install the LaTeX toolchain
--no-latex         skip the LaTeX toolchain

--dry-run          print the installation plan only
--non-interactive  use defaults without prompting

-h, --help         show help
```

---

# Choices a user must make

The installer intentionally does not guess personal or security-sensitive information.

## 1. Catppuccin flavor

All four Catppuccin flavors are supported:

| Flavor | Character |
|---|---|
| Latte | Light |
| Frappé | Soft dark |
| Macchiato | Medium dark — **default** |
| Mocha | Darkest |

Switch at any time with:

```bash
theme latte
theme frappe
theme macchiato
theme mocha
```

The selection is stored locally in:

```text
~/.config/dotfiles/theme
```

Changing flavor does **not** modify tracked dotfiles.

## 2. Git identity

Shared Git behavior is tracked, but identities are local.

Configure:

```text
~/.config/git/local
```

Example:

```gitconfig
[user]
    name = Your Name
    email = you@example.com
```

A separate DR/work identity can be placed in:

```text
~/.config/git/drdk
```

Example:

```gitconfig
[user]
    name = Your Work Name
    email = you@work.example
```

The tracked Git configuration conditionally applies the DR profile for remotes matching the `drdk` GitHub organization.

## 3. SSH authentication

SSH authentication is intentionally not automated.

Supported approaches include:

- 1Password SSH Agent
- normal OpenSSH keys
- another existing SSH agent

Verify authentication with:

```bash
ssh -T git@github.com
```

## 4. GitHub CLI authentication

After installation:

```bash
gh auth login \
  --hostname github.com \
  --git-protocol ssh \
  --web \
  --skip-ssh-key
```

Multiple GitHub CLI accounts can be managed independently with:

```bash
gh auth switch
```

## 5. Commit signing

SSH commit signing is optional and user-specific.

For 1Password:

1. Open the SSH key in 1Password.
2. Choose **Configure Commit Signing**.
3. Copy the Git configuration snippet.
4. Put the signing configuration in `~/.config/git/local`.
5. Register the public key on GitHub as a **Signing key**.

Do not commit signing keys or user-specific signing configuration to this repository.

---

# Installation architecture

The top-level installer orchestrates independent component scripts:

```text
install.sh
│
├── scripts/install-system.sh
├── scripts/install-terra.sh
├── scripts/stow.sh
├── scripts/setup-local.sh
├── scripts/install-mise.sh
├── scripts/install-tmux-theme.sh
├── scripts/install-kde-theme.sh      optional
├── scripts/install-latex.sh          optional
├── ~/.local/bin/theme
└── scripts/verify.sh
```

Component scripts are intended to be individually callable and safe to rerun.

---

# Package ownership

Avoid installing the same tool through multiple package managers.

## Fedora / DNF

Machine-level and OS-integrated tools:

```text
bat
curl
eza
fd
fzf
gh
git
git-delta
neovim
ripgrep
sqlite
sqlite-devel
stow
tmux
wl-clipboard
zoxide
zsh
zsh-autosuggestions
zsh-syntax-highlighting
```

## Terra RPM repository

The reference setup uses Terra packages for:

```text
ghostty
mise
starship
```

These remain RPM-owned. mise itself is **not** installed by mise.

## mise

The tracked configuration is:

```text
~/.config/mise/config.toml
```

The current user-level developer toolset includes:

```text
dotnet
node
python
uv

lazygit
ast-grep
tree-sitter

dotnet:EasyDotnet
npm:@mermaid-js/mermaid-cli
npm:neovim
pipx:pynvim
```

`mise install` installs what is declared in the tracked config; the install script does not duplicate the tool list.

## Mason

Mason owns Neovim-specific binaries such as:

```text
angular-language-server
eslint-lsp
js-debug-adapter
json-lsp
lua-language-server
netcoredbg
roslyn
shfmt
stylua
texlab
vtsls
yaml-language-server
```

## Project-local tooling

Project formatters, linters, compilers, and repository-specific CLIs should remain project-owned.

Examples:

### .NET repository

```text
CSharpier
dotnet-ef
trx2junit
```

These belong in `.config/dotnet-tools.json`.

### Angular / TypeScript repository

```text
Prettier
ESLint
angular-eslint
typescript-eslint
TypeScript
Karma / other project test runner
```

These belong in `package.json`.

---

# GNU Stow layout

Each top-level configuration directory is a Stow package:

```text
bat/
bin/
fzf/
ghostty/
git/
lazygit/
mise/
nvim-lazyvim/
starship/
tmux/
zsh/
```

Stow is run with `--no-folding`.

This is intentional. Individual tracked files are linked into normal directories so tracked and machine-local files can coexist.

Example:

```text
~/.config/git/
├── config          -> dotfiles/git/...
├── themes/...      -> dotfiles/git/...
├── local           # local, not tracked
└── drdk            # local, not tracked
```

---

# Machine-local state

The following files are intentionally outside the repository:

```text
~/.config/dotfiles/
├── theme
├── ghostty.conf
├── git-theme
└── tmux-theme.conf

~/.config/git/
├── local
└── drdk
```

The first group is derived from the selected Catppuccin flavor.

The Git files contain user-specific identity and optional authentication/signing configuration.

---

# Catppuccin theming

The repository installs all four Catppuccin flavors and uses one local selector.

Default:

```text
macchiato
```

Accent where applicable:

```text
mauve
```

## KDE

All four global themes are installed with:

- Mauve accent
- Classic window decoration
- Catppuccin cursor theme

Known Plasma identifiers:

| Flavor | Global theme | Color scheme | Cursor |
|---|---|---|---|
| Latte | `Catppuccin-Latte-Mauve` | `CatppuccinLatteMauve` | `catppuccin-latte-mauve-cursors` |
| Frappé | `Catppuccin-Frappe-Mauve` | `CatppuccinFrappeMauve` | `catppuccin-frappe-mauve-cursors` |
| Macchiato | `Catppuccin-Macchiato-Mauve` | `CatppuccinMacchiatoMauve` | `catppuccin-macchiato-mauve-cursors` |
| Mocha | `Catppuccin-Mocha-Mauve` | `CatppuccinMochaMauve` | `catppuccin-mocha-mauve-cursors` |

## Ghostty

All four official Ghostty theme files are tracked under:

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

The source prompt configuration lives in:

```text
starship/.config/starship/template.toml
```

Four tracked runtime configurations are generated:

```text
catppuccin-latte.toml
catppuccin-frappe.toml
catppuccin-macchiato.toml
catppuccin-mocha.toml
```

Regenerate after changing the template:

```bash
./scripts/update-starship-themes.sh
```

The shell selects one using `STARSHIP_CONFIG`.

The current prompt is based on Starship's Catppuccin Powerline preset, with:

- `.NET` added to the runtime section
- the command prompt on a second line
- command-duration notifications currently enabled

The Powerline layout may be simplified later.

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

Bat uses its packaged Catppuccin themes.

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

---

# Ghostty

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

# tmux

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

---

# Zsh

The startup model is deliberately simple.

## `~/.zshenv`

Only early environment configuration belongs here:

```zsh
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
export PATH="$HOME/.local/bin:$PATH"
```

## `~/.config/zsh/.zshrc`

Contains:

- history configuration
- local Catppuccin flavor selection
- Lazygit/Bat/fzf/Starship theme selection
- zoxide
- fzf integration
- autosuggestions
- aliases
- mise activation
- Starship
- syntax highlighting

The configuration intentionally avoids Oh My Zsh or another shell framework.

Useful navigation:

```text
Ctrl-R    fuzzy history search
Ctrl-T    fuzzy file insertion
Alt-C     fuzzy cd

z foo     zoxide ranked directory jump
zi        interactive zoxide selection
```

---

# Git and GitHub workflow

Responsibilities:

```text
Git
    source control

Lazygit
    repo-wide staging, commits, rebases, conflict work

LazyVim / Gitsigns / Snacks
    in-buffer hunks, blame, history, diff navigation

gh
    GitHub PRs, issues, checks, review, API
```

Shared Git defaults include:

- default branch `main`
- fetch pruning
- automatic upstream setup on first push
- rerere
- histogram diff algorithm
- Delta pager
- Neovim as editor
- conditional work identity includes

Typical GitHub CLI workflow:

```bash
gh pr status
gh pr list
gh pr create --fill
gh pr view
gh pr checks
gh pr checks --watch
gh pr checkout 123
gh pr review 123
```

Useful LazyVim Git mappings:

```text
<leader>gg    Lazygit

]h            next Git hunk
[h            previous Git hunk

<leader>ghp   preview hunk
<leader>ghs   stage hunk
<leader>ghr   reset hunk

<leader>gp    GitHub pull requests
<leader>gi    GitHub issues
<leader>gB    open current file/line on GitHub
<leader>gY    copy GitHub URL
```

Fugitive and Octo are intentionally not installed at present.

---

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

---

# .NET development

The .NET setup separates language support, testing, and debugging.

```text
roslyn.nvim
    C# language intelligence

EasyDotnet
    solution/project awareness
    native MTP/xUnit test runner

nvim-dap
    generic debugger framework

Mason netcoredbg
    .NET debugger backend

mise
    .NET SDK/runtime
```

EasyDotnet's own LSP integration is disabled; Roslyn is owned by `roslyn.nvim`.

## Testing

The tested setup uses:

- xUnit v3
- Microsoft Testing Platform
- EasyDotnet native test runner

C# buffers preserve LazyVim's test semantics:

```text
<leader>tr    Run Nearest
<leader>tt    Run File
<leader>td    Debug Nearest
```

Open the EasyDotnet test explorer with:

```vim
:Dotnet testrunner
```

It is configured as a right-side vertical split.

## Debugging

EasyDotnet's project-aware DAP registration is intentionally disabled.

On the reference project it successfully built a selected project but then failed with:

```text
No binary path supplied
```

The reliable setup is therefore:

- Mason-managed `netcoredbg`
- `nvim-dap`
- generic `NetCoreDbg: Launch`

Repository-specific `.vscode/launch.json` files are considered project configuration rather than workstation configuration.

## Formatting

C# formatting uses project-local CSharpier through Conform.

---

# Angular / TypeScript development

The frontend setup uses:

```text
VTSLS
Angular Language Server
ESLint Language Server
Conform
project-local Prettier
project-local ESLint/angular-eslint
```

Prettier remains project-local:

```bash
npm install --save-dev prettier
```

ESLint remains project-local.

The editor-side `eslint-lsp` is Mason-managed.

ESLint handles diagnostics/code actions; Prettier owns formatting.

---

# LaTeX

LaTeX support is optional:

```bash
./install.sh --latex
```

or:

```bash
./scripts/install-latex.sh
```

Fedora owns the TeX distribution and Biber.

Mason owns `texlab`.

Mermaid CLI (`mmdc`) is installed through mise/npm.

Perl and Ruby are not separately managed through mise merely because TeX utilities use them.

---

# Verification

Run:

```bash
./scripts/verify.sh
```

The verifier checks:

- required core commands
- Stow-managed links
- machine-local theme state
- required theme assets
- derived Ghostty/Delta/tmux theme overrides
- Git local configuration
- mise configuration and commands
- Mason editor tooling
- Neovim startup/version
- Catppuccin tmux installation/version
- nested Git repositories
- obvious generated junk files

Missing essential components are failures. Optional/editor-specific omissions may be warnings.

---

# Updating Starship themes

Edit only:

```text
starship/.config/starship/template.toml
```

Then regenerate:

```bash
./scripts/update-starship-themes.sh
```

The generated flavor configs are also tracked so a clone can be used without running generation first.

---

# Repository hygiene

Do not vendor entire third-party plugin repositories inside Stow packages.

Catppuccin tmux, for example, lives in:

```text
~/.local/share/tmux/plugins/catppuccin
```

and is installed by a pinned installer script.

Do not commit:

- Git identities
- private keys
- tokens
- machine-local theme state
- runtime logs
- nested Git repositories

---

# Troubleshooting

## `sudo`, `git`, or other `/usr/bin` commands suddenly disappear

In Zsh, `path` is a special array tied directly to `PATH`.

Do **not** use `path` as a casual variable:

```zsh
# Bad
path="$(command -v something)"
```

Use:

```zsh
cmd_path="$(command -v something)"
```

## Theme switching does not affect an existing shell

Run:

```bash
exec zsh
```

The `theme` Zsh wrapper normally does this automatically.

## Neovim does not update immediately after a theme switch

Refocus the Neovim window. The Catppuccin config checks the machine-local theme on `FocusGained`.

## EasyDotnet warns that its Roslyn LSP is disabled

Expected. Roslyn is owned by `roslyn.nvim`.

## EasyDotnet warns about `dotnet ef`

A repository-local `dotnet-ef` tool is preferred when the project requires it.

## Ghostty cannot find packaged themes on Fedora/Terra

The Terra Ghostty RPM may omit the upstream bundled theme collection.

This repository tracks the four required Catppuccin Ghostty theme files directly.

## `pynvim` is not an executable

Expected. Verify the Python provider through Neovim health checks instead.

---

# Manual post-install checklist

After a fresh install:

1. Configure `~/.config/git/local`.
2. Optionally configure `~/.config/git/drdk`.
3. Configure SSH authentication.
4. Configure optional SSH commit signing.
5. Run `gh auth login`.
6. Start Neovim and allow lazy.nvim/Mason to complete setup.
7. Run:

   ```bash
   ./scripts/verify.sh
   ```

8. Confirm Git identity:

   ```bash
   git config --show-origin --get user.name
   git config --show-origin --get user.email
   ```

9. Confirm GitHub SSH:

   ```bash
   ssh -T git@github.com
   ```

10. Confirm the selected theme:

    ```bash
    cat ~/.config/dotfiles/theme
    ```

---

# Current defaults

```text
Distribution:         Fedora
Desktop:              KDE Plasma / Wayland
Terminal:             Ghostty
Shell:                Zsh
Prompt:               Starship
Terminal persistence: tmux
Editor:               Neovim + LazyVim
Git TUI:              Lazygit
GitHub CLI:           gh
Runtime manager:      mise
Theme:                Catppuccin Macchiato
Accent:               Mauve
KDE decoration:       Classic
```

The goal is not to turn the workstation into a custom framework. The goal is a reproducible setup that remains understandable to someone already familiar with Fedora, Zsh, Neovim, Git, and the upstream tools themselves.

