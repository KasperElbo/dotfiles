# Installation architecture

The repository has platform-specific ownership layers around one portable core:

| Layer | Owns | Must not own |
|---|---|---|
| Portable common | Shared Stow packages, user-local Git/theme state, mise tools, opam switch/tool setup, and the tmux theme | Native package-manager installation, services, hardware, desktop integration, or OS-specific paths |
| `platforms/fedora` | DNF/Terra packages, including the opam binary and OCaml build prerequisites; KDE and Sway integration; system services; SELinux/system paths; Secure Boot; and ASUS hardware | Copies of shared Zsh/Git/Neovim/tmux/mise configuration or OCaml packages inside opam switches |
| `platforms/fedora-wsl` | WSL detection, CLI prerequisites, early Windows PATH isolation, explicit clipboard/browser interop and WSL verification | Fedora desktop, Ghostty, hardware, GPU, VM host/guest, invasive host networking changes, credentials or copies of portable configuration |
| `platforms/macos` | Native `/opt/homebrew` packages, AeroSpace, Mac shell paths, deliberate defaults, Podman machine integration, and arm64/security verification | Copies of shared configuration, Rosetta, Intel Homebrew, weakened SIP/Gatekeeper, identities, credentials, or Fedora service assumptions |
| `platforms/parrot-ctf` | Parrot/APT prerequisites, KVM/SPICE guest agents, Debian command shims, reduced LazyVim/Mason selection, a narrow uv/Neovim mise manifest, and lab/PATH-boundary verification | Fedora/Terra/KDE/ASUS provisioning, host virtualization, mise-managed system Python/security tools, credentials, shared folders, or a duplicate Parrot security-tool catalogue |

The shared Stow package directories remain at the repository root to preserve
existing symlink targets. `common/stow.sh` is their authoritative package
manifest and deployment entry point. Each platform installer calls the common
scripts directly and then adds only its own integration layer.
`common/stow.sh --headless` omits the Linux GUI terminal package for the WSL
composition without changing the normal Fedora manifest.
`common/stow.sh --headless --without-mise` lets the Parrot profile substitute
its narrow lab manifest without inheriting general-workstation runtimes.

macOS reuses the full common workstation manifest. Its own Stow packages are
AeroSpace, the Homebrew-specific Zsh path/plugin hooks, and a small VimTeX
PDF-viewer override for the shared Neovim/LazyVim configuration.

Fedora-specific shell paths and theme behavior are injected through tracked
platform files under `platforms/fedora/stow`; the portable Zsh and `theme`
configurations contain no Fedora path or service assumptions. Machine-local
identities, authentication, output layout, and selected theme remain outside
the repository.

## Entry points

`./install.sh` is a thin front door: it chooses a Bash to run under — on macOS
that means `scripts/bootstrap-macos.sh` first, because the system ships Bash
3.2 — and then execs `scripts/install-main.sh`, which parses the shared options
and hands off to `platforms/<platform>/install.sh`. That platform installer is
what builds the
execution plan below; it is also a supported entry point on its own, for
installing exactly one platform.

<!-- BEGIN GENERATED INSTALL FLOWS -->

<!-- Generated from the plan_add calls in platforms/*/install.sh by
     scripts/render-install-flows.py. Do not edit between these markers;
     edit the installer and regenerate. -->

## Per-platform install flow

Every installer builds one ordered execution plan and then runs it. The
tables below are that plan, read out of the installers themselves, so the
order here is the order `--dry-run` prints and an apply run executes:

```bash
./install.sh --platform <platform> --dry-run
```

Add the optional flags you intend to use: a **conditional** step is planned
only when its option selects it, and `--dry-run` resolves that for the exact
selection you pass. The `verify` phase runs after every `apply` step it
follows, and component scripts stay individually callable and safe to rerun.

### Fedora workstation

`platforms/fedora/install.sh`, 24 steps:

| # | Step | Phase | When | What it does |
|---|---|---|---|---|
| 1 | `system` | `apply` | always | Install Fedora system packages |
| 2 | `terra` | `apply` | always | Enable Terra and install Terra-managed packages |
| 3 | `ocaml-native` | `apply` | conditional | Install Fedora-owned OCaml prerequisites |
| 4 | `hardware` | `apply` | conditional | Install ASUS hardware support for `<hardware-model>` |
| 5 | `sway` | `apply` | conditional | Install the optional Sway daily-driver session |
| 6 | `vm-host` | `apply` | conditional | Install the optional Fedora KVM/QEMU + libvirt VM-host profile |
| 7 | `vm-guest` | `apply` | conditional | Install the explicit Fedora KVM/QEMU VM-guest profile |
| 8 | `hardening` | `apply` | conditional | Install the optional conservative security-hardening profile |
| 9 | `desktop-tools` | `apply` | conditional | Install the optional day-to-day desktop application profile |
| 10 | `dictation` | `apply` | conditional | Install the optional voice-dictation profile |
| 11 | `containers` | `apply` | conditional | Install the optional rootless Podman profile |
| 12 | `tailscale` | `apply` | conditional | Install the optional Tailscale networking profile |
| 13 | `local` | `apply` | always | Initialize machine-local configuration |
| 14 | `stow` | `apply` | always | Deploy tracked configuration with GNU Stow |
| 15 | `mise` | `apply` | always | Install mise-managed runtimes and developer tools |
| 16 | `nvim` | `apply` | always | Restore LazyVim and install the Mason inventory |
| 17 | `tmux` | `apply` | always | Install the pinned Catppuccin tmux theme |
| 18 | `ocaml` | `apply` | conditional | Create the opam-owned OCaml switch and Platform tools |
| 19 | `ai` | `apply` | conditional | Install the optional AI-assisted development profile |
| 20 | `kde` | `apply` | conditional | Install all four Catppuccin KDE themes |
| 21 | `latex` | `apply` | conditional | Install LaTeX toolchain |
| 22 | `theme` | `apply` | always | Apply Catppuccin `<theme>` |
| 23 | `dev-workflows` | `verify` | conditional | Run the disposable development workflow smoke tests |
| 24 | `verify` | `verify` | always | Verify installation |

### Fedora on WSL

`platforms/fedora-wsl/install.sh`, 14 steps:

| # | Step | Phase | When | What it does |
|---|---|---|---|---|
| 1 | `system` | `apply` | always | Install Fedora command-line prerequisites and Linux-native mise |
| 2 | `interop` | `apply` | always | Preserve explicit Windows executable interop without Windows PATH entries |
| 3 | `ocaml-native` | `apply` | conditional | Install Fedora OCaml build prerequisites |
| 4 | `latex` | `apply` | conditional | Install the optional Fedora-owned LaTeX toolchain |
| 5 | `local` | `apply` | always | Initialize machine-local Git and theme state |
| 6 | `stow` | `apply` | always | Deploy portable and Fedora WSL configuration |
| 7 | `mise` | `apply` | always | Install mise-managed Linux runtimes and developer CLIs |
| 8 | `nvim` | `apply` | always | Restore LazyVim and install the Mason inventory |
| 9 | `ocaml` | `apply` | conditional | Create the opam-owned OCaml switch |
| 10 | `containers` | `apply` | conditional | Install the optional rootless Podman profile |
| 11 | `tmux` | `apply` | always | Install the pinned Catppuccin tmux theme |
| 12 | `ai` | `apply` | conditional | Install the optional AI-assisted development profile |
| 13 | `theme` | `apply` | always | Apply the selected theme |
| 14 | `verify` | `verify` | always | Verify WSL detection, Linux command ownership, and runtime startup |

### Apple Silicon macOS

`platforms/macos/install.sh`, 17 steps:

| # | Step | Phase | When | What it does |
|---|---|---|---|---|
| 1 | `system` | `apply` | always | Verify native arm64 macOS and install the Homebrew baseline |
| 2 | `ocaml-native` | `apply` | conditional | Install Homebrew OCaml prerequisites |
| 3 | `containers` | `apply` | conditional | Install and start a rootless Podman machine |
| 4 | `tailscale` | `apply` | conditional | Install the optional Tailscale profile (Homebrew cask, interactive login). |
| 5 | `dictation` | `apply` | conditional | Install the optional dictation profile (pinned Ghost Pepper disk image). |
| 6 | `local` | `apply` | always | Initialize local Git and theme state |
| 7 | `stow` | `apply` | always | Deploy shared and macOS configuration |
| 8 | `mise` | `apply` | always | Install mise-managed runtimes |
| 9 | `nvim` | `apply` | always | Restore LazyVim and Mason tools |
| 10 | `tmux` | `apply` | always | Install the pinned Catppuccin tmux theme |
| 11 | `ocaml` | `apply` | conditional | Create the opam-owned OCaml switch and platform tools |
| 12 | `ai` | `apply` | conditional | Install the optional AI-assisted development profile |
| 13 | `defaults` | `apply` | conditional | Apply reversible Dock, Finder, screenshot, keyboard, and Mission Control defaults |
| 14 | `dev-workflows` | `verify` | conditional | Run the disposable development workflow smoke tests |
| 15 | `theme` | `apply` | always | Apply the selected theme |
| 16 | `aerospace` | `apply` | always | Launch AeroSpace |
| 17 | `verify` | `verify` | always | Verify installation and native architecture |

### Parrot Security Edition CTF guest

`platforms/parrot-ctf/install.sh`, 10 steps:

| # | Step | Phase | When | What it does |
|---|---|---|---|---|
| 1 | `system` | `apply` | always | Install Parrot-owned working-environment prerequisites |
| 2 | `guest` | `apply` | always | Install and activate KVM/QEMU guest integration |
| 3 | `local` | `apply` | always | Initialize machine-local Git and theme state |
| 4 | `stow` | `apply` | always | Deploy the reduced portable and narrow Parrot configuration |
| 5 | `terminal` | `apply` | always | Install the pinned Nerd Font, bat themes, and Konsole profile |
| 6 | `mise` | `apply` | always | Install the narrow mise-managed uv and Neovim runtimes |
| 7 | `nvim` | `apply` | always | Restore the reduced LazyVim/Mason inventory for Parrot |
| 8 | `tmux` | `apply` | always | Install the pinned Catppuccin tmux theme |
| 9 | `theme` | `apply` | always | Apply the selected theme |
| 10 | `verify` | `verify` | always | Verify the complete Parrot guest |

<!-- END GENERATED INSTALL FLOWS -->

## What a plan action may assume

`plan_execute` runs each step's action as the condition of an `if`, so it can
report which step failed and what was left pending rather than letting the
whole installer abort at the point of failure. Bash ignores `errexit` for an
`if` condition and for everything that condition runs, however deep, so **an
action runs with `errexit` suppressed and must handle its own failures
explicitly.**

In practice that means an action whose fallible command is its last statement
needs nothing — its status is the function's status, which is the ordinary
shape and the one nearly every action uses. An action that runs anything
*after* a fallible command has to write `|| return` on that command, or the
failure is discarded and the step is reported as completed.

The boundary cannot be a subshell, which is how
[`common/lib/theme-hooks.sh`](../../common/lib/theme-hooks.sh) solves the same
problem for theme hooks: an action such as macOS's `activate_homebrew_path`
mutates `PATH` for the steps that follow and has to run in the installer's own
shell. Every construct that captures a failure without aborting suppresses
`errexit` the same way, so the contract is stated rather than enforced by the
boundary.

`tests/test-execution-plan.sh` covers both shapes, and holds a negative control
that fails if the boundary ever starts propagating on its own — so this section
cannot quietly go stale.

The historical `scripts/*.sh` paths remain thin compatibility entry points for
Fedora; see [repository conventions](repository-conventions.md#deprecated-wrappers).
