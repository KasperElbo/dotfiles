# Repository conventions

Conventions for changing this repository itself, as opposed to operating a
machine it has installed.

## Repository hygiene

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

Do not leave a package manager's lockfile at the repository root without the
project it belongs to. `./scripts/lint.sh` rejects a lone root lockfile: it
makes dependency and supply-chain tooling treat this repository as a project it
is not.

## Entry points, and what `scripts/` actually is

A file living under `scripts/` is not automatically a public, cross-platform
command. There are five distinct kinds of executable in this repository, and
`config/shell-file-roles.tsv` records which one every tracked shell file is:

| Kind | Where | What it means |
|---|---|---|
| **Portable entry point** | `./install.sh`, `./doctor`, `./scripts/lint.sh`, `./scripts/test.sh` | Works on every supported platform. These are the documented way in. |
| **Platform command** | `platforms/<platform>/install.sh`, `platforms/<platform>/scripts/*.sh` | Belongs to exactly one platform and says so in its path. Safe to run directly when you want one component. |
| **Portable wrapper** | `scripts/install-ai.sh`, `scripts/install-mise.sh`, `scripts/install-neovim-tools.sh`, `scripts/install-tmux-theme.sh`, `scripts/verify-ai.sh` | A supported alias for the matching `common/` script. Not deprecated: the target really is portable. |
| **Deprecated compatibility wrapper** | every other `scripts/*.sh`, plus `scripts/lib/*.sh` | A Fedora-only path from before the platform layout existed. Still forwards; see below. |
| **Internal implementation** | `common/*.sh`, `scripts/install-main.sh`, `scripts/bootstrap-macos.sh` | Called by the installers. Individually rerunnable, but not the documented interface. |

### Deprecated wrappers

`scripts/install-sway.sh` and its siblings look cross-platform and are not:
they forward to `platforms/fedora/`. Repository search cannot prove nobody
outside this repository invokes them, so they are not being removed on that
evidence.

Each one now prints a single notice to stderr — never stdout, so a caller
parsing output is unaffected — naming the supported replacement, the platform
script it forwards to, and the date before which it will not be removed. The
forwarding itself is unchanged. `DOTFILES_SUPPRESS_DEPRECATION=1` silences the
notice for scripted use.

```text
DEPRECATED: scripts/install-sway.sh is a compatibility wrapper.
            Use ./install.sh --platform fedora --sway instead.
            For this component alone, run platforms/fedora/scripts/install-sway.sh.
            It keeps working, and is removed no earlier than 2027-03-15.
```

The removal date lives in one place, `common/lib/deprecation.sh`, so the window
is one decision rather than a date copied into thirty files. **Removal is a
separate, later change**, not part of the deprecation: nothing here removes a
wrapper, and nothing should until that date has passed.

### File modes

The executable bit is a contract: it says "this is an entry point you may run".
`config/shell-file-roles.tsv` gives every tracked shell file exactly one role
and one mode — `0755` for anything meant to be executed, `0644` for anything
meant to be sourced — and `./scripts/lint.sh` enforces it. A file matching no
role fails too: classifying a new script is part of adding it.

### Names say what a file does

Three unrelated files were once called `theme-state.sh`. They are now named for
their responsibility:

| File | Responsibility |
|---|---|
| `common/lib/theme-shared-state.sh` | Writes the derived state files every platform reads |
| `platforms/fedora/lib/theme-desktop.sh` | Generates and applies the Fedora desktop half: Sway, Waybar, Fuzzel, Mako, swaylock, wallpaper, cursor |
| `scripts/lib/theme-state.sh` | Deprecated shim that forwards to the first |

## Licensing

This repository's own scripts, configuration and documentation have **no
licence yet**; that is an open maintainer decision, with the options and their
practical consequences written down in
[`docs/reference/licensing.md`](../reference/licensing.md). Until it is made,
the default applies: all rights reserved.

Third-party material vendored or fetched here keeps its own upstream licence,
which that decision cannot change. What is incorporated, at which upstream
revision, and under which licence is indexed in
[`docs/reference/third-party-notices.md`](../reference/third-party-notices.md).
Retained upstream licence texts live in [`LICENSES/`](../../LICENSES) and beside the
material they cover.
