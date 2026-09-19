# Development and Security-Lab Dotfiles

Opinionated, reproducible dotfiles for a keyboard-driven development
workstation, and for the security-lab guest next to it. One installer, one
portable core, and a thin platform layer per target:

| Platform | Guide | What it is |
|---|---|---|
| Fedora workstation | [docs/platforms/fedora.md](docs/platforms/fedora.md) | The reference target: KDE Plasma/Wayland, an optional Sway session, optional laptop hardware support |
| Fedora on WSL | [docs/platforms/fedora-wsl.md](docs/platforms/fedora-wsl.md) | A Linux development runtime with Windows as the desktop and terminal host |
| Apple Silicon macOS | [docs/platforms/macos.md](docs/platforms/macos.md) | Native `arm64` with AeroSpace for a keyboard-first desktop |
| Parrot Security Edition | [docs/platforms/parrot-ctf.md](docs/platforms/parrot-ctf.md) | A deliberately disposable KVM/QEMU CTF guest |

The everyday toolchain is the same everywhere it can be: Ghostty, Zsh,
Starship, Neovim + LazyVim, tmux, Git + GitHub CLI + Lazygit, mise-managed
language runtimes, an optional opam-managed OCaml environment, and Catppuccin
across the desktop, terminal, editor and CLI tools.

The configuration stays close to upstream defaults. Custom behavior is added
only where it solves a concrete workflow problem.

## Design principles

1. **Use the native package manager for machine-level tools.** Fedora/DNF,
   Parrot/APT, or native Apple Silicon Homebrew owns operating-system and
   integrated tools.
2. **Use mise for general language runtimes and portable developer CLIs.**
   Ecosystems with their own switch model, such as OCaml/opam, remain with
   their native manager.
3. **Use Mason only for Neovim-specific tooling.** Tooling that must match a
   language environment stays with that environment.
4. **Keep project tooling in the project.** CSharpier, Prettier, ESLint,
   `dotnet-ef`, TypeScript, etc. should normally be declared by the repository
   that uses them.
5. **Keep shared configuration tracked and user-specific state local.**
6. **Prefer upstream workflows over custom glue.**

---

## Quick start

Clone the repository, look at the plan, then install:

```bash
mkdir -p ~/src
git clone <REPOSITORY_URL> ~/src/dotfiles
cd ~/src/dotfiles

./install.sh --dry-run      # resolve and print the plan; change nothing
./install.sh                # install with the defaults
```

`--platform` selects a target other than the default Fedora workstation:

```bash
./install.sh --platform fedora-wsl --dry-run
./install.sh --platform macos --dry-run
./install.sh --platform parrot-ctf --dry-run
```

Every option, its default and its permitted values are in
[docs/reference/installer-options.md](docs/reference/installer-options.md),
generated from the installer's own manifest. The step-by-step path — including
the reboot the login-shell change needs and the post-install checklist — is
[docs/workflows/install.md](docs/workflows/install.md).

## Safety and ownership model

The installer is meant to be run repeatedly on a machine you use every day, so
it is built around a few rules that do not bend:

- **Nothing personal or secret is in this repository, and none of it is
  generated for you.** Git identities, SSH keys, tokens, signing configuration
  and tailnet membership stay machine-local; the installer never writes them
  and never logs them. What you have to set up yourself is listed in
  [docs/workflows/first-run.md](docs/workflows/first-run.md).
- **Optional profiles are opt-in and independent.** A default install adds no
  desktop tools, no containers, no VM stack, no Tailscale, no hardening and no
  AI tooling. Which capabilities exist on which platform, and who provides
  each one, is in
  [docs/reference/capability-matrix.md](docs/reference/capability-matrix.md),
  generated from `config/capabilities.tsv`.
- **`--dry-run` never mutates**, on any platform or profile, whether or not
  that profile's preconditions are currently met.
- **Reruns are safe.** Every component script is individually callable and
  idempotent, and a rerun preserves the machine's existing theme, local
  configuration and unrelated files.
- **A failed run leaves the previous good state recorded.** Only a completely
  successful install replaces what `--rerun` reapplies.
- **What is not verified is said to be not verified.** Verifiers separate what
  this repository owns from what the platform owns and from what only a human
  can judge.

## Configuration management model

Tracked configuration is deployed with GNU Stow, one package per tool, with
`--no-folding` so tracked links and machine-local files coexist in the same
directory. Machine-local state — the selected theme, installed-profile
records, Git identities, Sway output overrides — lives under
`~/.config/dotfiles`, `~/.local/state/dotfiles` and `~/.config/git`, and is
never tracked. See
[docs/architecture/file-ownership.md](docs/architecture/file-ownership.md).

Seven manifests under `config/` are the normative contract the code and the
documentation both read:

| Manifest | Owns |
|---|---|
| `config/capabilities.tsv` | Which capability exists on which platform, its provider, packages and their installers, Stow packages, verifier, state file and documentation |
| `config/install-options.tsv` | Every persistent installer option: flag spelling, kind, default, permitted values |
| `config/network-sources.tsv` | Every network source the repository fetches, its provenance tier, privilege and integrity mechanism |
| `config/command-providers.tsv` | The pre-mutation command closure of every bash platform: which capability owns each native command |
| `config/actions.tsv` | Every repository-defined user action: binding, platform, source, how it is discoverable, and whether a printable sheet carries it |
| `config/shell-file-roles.tsv` | Every tracked shell file's role and required file mode |
| `config/terra-keys.tsv` | The reviewed Terra signing-key fingerprint pinned for each Fedora release |

Documentation that states a supported capability, an option, a default or a
provider is generated from these manifests or checked against them; see
[docs/capabilities.md](docs/capabilities.md) and
[docs/README.md](docs/README.md#document-roles).

## Install, rerun, doctor

```bash
./install.sh --dry-run          # plan only
./install.sh                    # install
./install.sh --rerun            # reapply this machine's last successful configuration
./install.sh --rerun --dry-run  # show what that would apply
./doctor                        # read-only health report; changes nothing
```

`--rerun` means "apply the remembered *configuration* with the installer in
this checkout" — not "run the old command again". The machine remembers the
resolved selection of its last successful install; the implementation is
always the current one. No stored command text is ever executed. See
[docs/workflows/rerun.md](docs/workflows/rerun.md).

`./doctor` reports whether the recorded lifecycle state is valid, whether the
checkout matches the installed revision, whether each selected capability's
state is present, and whether a configuration is available for `--rerun`. It
never prints the record itself and never changes anything.

## Verifying an installation

```bash
./platforms/fedora/scripts/verify.sh   # each platform has its own verifier
```

See [docs/workflows/verification.md](docs/workflows/verification.md) for what
verification proves, and [docs/testing.md](docs/testing.md) for the test
architecture behind it.

## Documentation

[docs/README.md](docs/README.md) is the index, and explains which document is
authoritative for what. The usual starting points:

- **Install and operate** — [install](docs/workflows/install.md),
  [first-run choices](docs/workflows/first-run.md),
  [rerun](docs/workflows/rerun.md),
  [verification](docs/workflows/verification.md),
  [troubleshooting](docs/troubleshooting.md)
- **Platforms** — [Fedora](docs/platforms/fedora.md),
  [Fedora on WSL](docs/platforms/fedora-wsl.md),
  [macOS](docs/platforms/macos.md),
  [Parrot CTF](docs/platforms/parrot-ctf.md)
- **Optional profiles** — [containers](docs/profiles/containers.md),
  [VM host](docs/profiles/vm-host.md), [VM guest](docs/profiles/vm-guest.md),
  [hardening](docs/profiles/hardening.md),
  [desktop tools](docs/profiles/desktop-tools.md),
  [dictation](docs/profiles/dictation.md),
  [Tailscale](docs/profiles/tailscale.md), [AI toolchain](docs/profiles/ai.md)
- **Daily workflows** — [shell](docs/workflows/shell.md),
  [terminal](docs/workflows/terminal.md), [theming](docs/workflows/theming.md),
  [Git](docs/workflows/git.md), [editor](docs/workflows/editor.md),
  [languages and projects](docs/workflows/development.md),
  [LaTeX](docs/workflows/latex.md)
- **Reference** — [installer options](docs/reference/installer-options.md),
  [capability matrix](docs/reference/capability-matrix.md),
  [keyboard and workflow reference](docs/reference/keybindings.md),
  [current defaults](docs/reference/defaults.md)
- **Architecture and provenance** —
  [installation architecture](docs/architecture/installation.md),
  [package ownership](docs/architecture/package-ownership.md),
  [file ownership](docs/architecture/file-ownership.md),
  [supply chain](docs/supply-chain.md)

## Licensing

This repository's own scripts, configuration and documentation are **MIT
licensed** — see [LICENSE](LICENSE). Copy, modify and redistribute them,
including in closed-source work, as long as the copyright notice travels with
them. There is no warranty; read the installers before running them on a
machine you care about.

Third-party material vendored or fetched here keeps its own upstream licence,
which that choice does not change. What is incorporated, at which upstream
revision, and under which licence is indexed in
[docs/reference/third-party-notices.md](docs/reference/third-party-notices.md).
Retained upstream licence texts live in [LICENSES/](LICENSES/) and beside the
material they cover. [docs/reference/licensing.md](docs/reference/licensing.md)
records the decision and what was considered.

## Contributing to this checkout

Before opening a pull request, run the same read-only validation CI runs:

```bash
./scripts/lint.sh
./scripts/test.sh
git diff --check
```

Repository conventions — what must never be committed, and how generated files
and documentation are kept honest — are in
[docs/architecture/repository-conventions.md](docs/architecture/repository-conventions.md).

---

The goal is not to turn the workstation into a custom framework. The goal is a
reproducible setup that remains understandable to someone already familiar with
Fedora, Zsh, Neovim, Git, and the upstream tools themselves.
