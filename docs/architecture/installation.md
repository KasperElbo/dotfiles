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

The current Fedora flow is:

```text
install.sh                         compatibility entry point
│
└── platforms/fedora/install.sh
    ├── platforms/fedora/scripts/install-system.sh
    ├── platforms/fedora/scripts/install-terra.sh
    ├── platforms/fedora/scripts/install-ocaml.sh          optional prerequisites
    ├── platforms/fedora/scripts/install-asus-hardware.sh  optional
    ├── platforms/fedora/scripts/install-sway.sh           optional
    ├── common/setup-local.sh
    ├── platforms/fedora/scripts/setup-local.sh
    ├── common/stow.sh
    ├── platforms/fedora/scripts/stow.sh
    ├── common/install-mise.sh
    ├── common/install-neovim-tools.sh
    ├── common/install-ocaml.sh                            optional switch/tools
    ├── common/install-tmux-theme.sh
    ├── platforms/fedora/scripts/install-kde-theme.sh      optional
    ├── platforms/fedora/scripts/install-latex.sh          optional
    ├── platforms/fedora/scripts/install-vm-host.sh        optional
    ├── platforms/fedora/scripts/install-vm-guest.sh       optional, guest only
    ├── platforms/fedora/scripts/install-hardening.sh      optional
    ├── ~/.local/bin/theme + Fedora theme hook
    └── platforms/fedora/scripts/verify.sh
```

The historical `scripts/*.sh` paths remain thin compatibility entry points for
Fedora. Component scripts are individually callable and safe to rerun.

The Fedora WSL flow is deliberately smaller:

```text
install.sh --platform fedora-wsl
│
└── platforms/fedora-wsl/install.sh
    ├── platforms/fedora-wsl/scripts/install-system.sh
    ├── platforms/fedora/scripts/install-ocaml.sh       optional prerequisites
    ├── common/setup-local.sh
    ├── common/stow.sh --headless
    ├── platforms/fedora-wsl/scripts/stow.sh
    ├── common/install-mise.sh
    ├── common/install-neovim-tools.sh
    ├── common/install-ocaml.sh                         optional switch/tools
    ├── common/install-tmux-theme.sh
    └── platforms/fedora-wsl/scripts/verify.sh
```

The Parrot CTF flow is a separate guest-only composition:

```text
install.sh --platform parrot-ctf
│
└── platforms/parrot-ctf/install.sh
    ├── Parrot + KVM/QEMU/channel preflight
    ├── platforms/parrot-ctf/scripts/install-system.sh
    ├── platforms/parrot-ctf/scripts/install-guest-integration.sh
    ├── common/setup-local.sh
    ├── common/stow.sh --headless --without-mise
    ├── platforms/parrot-ctf/scripts/stow.sh
    ├── common/install-mise.sh                         uv + pinned Neovim
    ├── common/install-neovim-tools.sh --profile parrot-ctf
    ├── common/install-tmux-theme.sh
    └── platforms/parrot-ctf/scripts/verify.sh
```
