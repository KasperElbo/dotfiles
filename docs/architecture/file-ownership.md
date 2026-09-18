# Stow layout and machine-local state

## GNU Stow layout

Each top-level configuration directory is a Stow package, and each platform
adds its own tree under `platforms/<platform>/stow/`.

<!-- BEGIN GENERATED STOW PACKAGES -->

<!-- Generated from the packages=( … ) arrays in common/stow.sh and
     platforms/*/scripts/stow.sh by scripts/render-file-ownership.py.
     Do not edit between these markers; edit the script and regenerate. -->

Every installation deploys the portable packages at the repository root
and then its own platform tree. `common/stow.sh` is the authoritative
manifest for the first; each platform's `stow.sh` is for the second.

| Tree | Packages |
|---|---|
| Portable (`common/stow.sh`) | `bat` `bin` `fzf` `ghostty` `git` `lazygit` `mise` `nvim-lazyvim` `starship` `tmux` `zsh` |
| Fedora workstation (`platforms/fedora/stow/`) | `sway` `theme-hooks` `waybar` `zsh-platform` |
| Fedora on WSL (`platforms/fedora-wsl/stow/`) | `interop` `nvim-wsl` `theme-hooks` `zsh-platform` |
| Apple Silicon macOS (`platforms/macos/stow/`) | `aerospace` `ghostty-macos` `nvim-macos` `zsh-platform` |
| Parrot Security Edition CTF guest (`platforms/parrot-ctf/stow/`) | `command-shims` `mise-ctf` `neovim-profile` `zsh-platform` |
| Shared (repository root, deployed by Fedora workstation) | `theme-assets` |

A shared row is a package at the repository root that `common/stow.sh`
does not deploy: the platforms named there link it, and there is one
copy of its contents rather than one per platform.

Not every package in a row is deployed on every run: `common/stow.sh
--headless` omits the GUI terminal package for the WSL composition,
`--without-mise` omits the general-workstation mise manifest for the
Parrot guest, and Fedora's `sway` and `waybar` packages are stowed only
with `--sway`.

<!-- END GENERATED STOW PACKAGES -->

Stow is run with `--no-folding`, and never with `--adopt`.

Because linking is the only thing Stow is allowed to do here, a path that
already exists where a tracked file would be linked is a conflict, not
something to absorb: preflight reports `Stow conflict [<package>]: ...` and the
install stops before any change is made. Move that path aside and rerun — see
[troubleshooting](../troubleshooting.md#stow-conflicts).

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

## Machine-local state

The files below are intentionally outside the repository. They fall into four
groups, and the difference matters when something needs to be reset: component
state records what an install did, theme state is derived and safe to
regenerate, lifecycle state is the installer's own bookkeeping, and the rest is
yours.

<!-- BEGIN GENERATED MACHINE-LOCAL STATE -->

<!-- Component state files are generated from the `state` column of
     config/capabilities.tsv by scripts/render-file-ownership.py.
     Do not edit between these markers; edit the manifest and regenerate. -->

### Component state — `~/.config/dotfiles/<component>.conf`

One file per installed component, recording what was requested and what was
observed. A profile's verifier and `--rerun` read these rather than asking
for a flag again. The manifest's `state` column is what names them:

| File | Written for |
|---|---|
| `~/.config/dotfiles/ai.conf` | `ai`, `backpass`, `codex`, `firstmate`, `gnhf` |
| `~/.config/dotfiles/containers.conf` | `containers` |
| `~/.config/dotfiles/desktop-tools.conf` | `desktop-tools` |
| `~/.config/dotfiles/hardening.conf` | `hardening` |
| `~/.config/dotfiles/hardware.conf` | `hardware` |
| `~/.config/dotfiles/macos-containers.conf` | `containers` |
| `~/.config/dotfiles/macos-tailscale.conf` | `tailscale` |
| `~/.config/dotfiles/ocaml.conf` | `ocaml` |
| `~/.config/dotfiles/parrot-ctf.conf` | `vm-guest` |
| `~/.config/dotfiles/tailscale.conf` | `tailscale` |
| `~/.config/dotfiles/vm-guest.conf` | `vm-guest` |
| `~/.config/dotfiles/vm-host.conf` | `vm-host` |

`hardware.conf` is created only after an optional hardware profile has
been installed; it records the selected model and verification
requirements.

### Theme state — `~/.config/dotfiles/`

Derived from the selected flavour every time `theme` runs:

| File | What it carries | Written by |
|---|---|---|
| `~/.config/dotfiles/theme` | the selected Catppuccin flavour | `common/lib/theme-shared-state.sh` |
| `~/.config/dotfiles/ghostty.conf` | Ghostty/Noctty theme include | `common/lib/theme-shared-state.sh` |
| `~/.config/dotfiles/git-theme` | the delta feature Git loads | `common/lib/theme-shared-state.sh` |
| `~/.config/dotfiles/tmux-theme.conf` | the tmux Catppuccin flavour | `common/lib/theme-shared-state.sh` |
| `~/.config/dotfiles/sway-theme.conf` | Sway colours | `platforms/fedora/lib/theme-desktop.sh` |
| `~/.config/dotfiles/waybar-theme.css` | Waybar colours | `platforms/fedora/lib/theme-desktop.sh` |
| `~/.config/dotfiles/fuzzel.ini` | Fuzzel colours | `platforms/fedora/lib/theme-desktop.sh` |
| `~/.config/dotfiles/mako.conf` | Mako colours | `platforms/fedora/lib/theme-desktop.sh` |
| `~/.config/dotfiles/swaylock.conf` | swaylock colours | `platforms/fedora/lib/theme-desktop.sh` |

The first four are portable. The rest are the Fedora desktop half and
exist only where that theme hook is installed.

### Lifecycle state — `$XDG_STATE_HOME/dotfiles/`

`$XDG_STATE_HOME` defaults to `~/.local/state`. This directory is state
the installer itself keeps, not configuration:

| Path | What it carries | Written by |
|---|---|---|
| `$XDG_STATE_HOME/dotfiles/install.conf` | the install lifecycle state `--rerun` reapplies | `common/lib/install-lifecycle.sh` |
| `$XDG_STATE_HOME/dotfiles/install.log` | the timestamped execution-plan log | `common/lib/install-lifecycle.sh` |
| `$XDG_STATE_HOME/dotfiles/theme-actions.log` | what each theme hook did, and whether it failed | `common/lib/theme-hooks.sh` |
| `$XDG_STATE_HOME/dotfiles/mise-context/` | the empty directory every mise invocation runs from | `common/lib/common.sh` |
| `$XDG_STATE_HOME/dotfiles/git-identity/` | backups taken before a Git identity migration | `common/lib/git-identity.sh` |

### Other machine-local files

| Path | What it carries |
|---|---|
| `~/.config/git/local` | machine-local Git identity and signing configuration |
| `~/.config/git/drdk` | a per-directory Git identity include |
| `~/.config/sway/local.conf` | output names, positions, modes, and scaling |
| `~/.config/mise/conf.d/ai.toml` | the untracked AI toolchain mise fragment |

<!-- END GENERATED MACHINE-LOCAL STATE -->

The Git files contain user-specific identity and optional
authentication/signing configuration; see
[the Git identity reference](../reference/git-identity.md).

When upgrading from a version that tracked these files accidentally,
`common/setup-local.sh` replaces the old Stow links with private local files
before the remaining dotfiles are restowed.
