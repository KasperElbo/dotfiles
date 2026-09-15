# Documentation index

The root [README](../README.md) is the entry point: what this repository is,
how to install it, and where to go next. Everything else lives here.

## Document roles

These are not interchangeable. When two of them appear to disagree, the one
higher in this list wins, and the lower one is a bug.

| Role | Where | What it is |
|---|---|---|
| 1. Structured contract | `config/*.tsv` | The normative, machine-readable source for capabilities, providers, installer options, network sources, the Fedora command closure, and every repository-defined user action. Code reads it; documentation is generated from it or checked against it. |
| 2. Generated reference | [reference/capability-matrix.md](reference/capability-matrix.md), [reference/installer-options.md](reference/installer-options.md), [reference/verifiers.md](reference/verifiers.md), [supply-chain-sources.md](supply-chain-sources.md) | Rendered from role 1. Never edited by hand; `./scripts/lint.sh` fails when one is stale. |
| 3. Platform and profile guides | [platforms/](platforms/), [profiles/](profiles/) | How to install and operate one target or one optional profile, including what it deliberately does not do. |
| 4. Workflow guides | [workflows/](workflows/) | How the day-to-day environment is used: installing, theming, shell, editor, languages. |
| 5. Full action reference | [reference/keybindings.md](reference/keybindings.md) | Every registered action, generated from `config/actions.tsv` — including the ones no printable sheet carries. Optimized for completeness and searching. |
| 6. Printable cheat sheets | [cheatsheets/](cheatsheets/) | Deliberately curated per-profile subsets of the same registry, sized for one or two printed A4 pages and verified against that budget. Never exhaustive. |
| 7. Rationale and history | [architecture/](architecture/), [parrot-ctf-shell-audit.md](parrot-ctf-shell-audit.md) | Why the structure is what it is, and what was rejected. |

A fact about a supported capability, an option, a default, a provider, or a
platform's support boundary has exactly one authoritative source: role 1.
Guides link to roles 2 and 5 rather than restating them.

Issue numbers belong in Git history and in rationale documents, never in the
current support contract. A guide never says a capability is "waiting for" or
"blocked on" an issue; it says what is true of this checkout.

## Contents

### Platforms

- [platforms/README.md](platforms/README.md) — the supported environment, and what is deliberately out of scope
- [platforms/fedora.md](platforms/fedora.md) — Fedora workstation: ASUS laptop hardware, keyboard layouts, the optional Sway session
- [platforms/fedora-wsl.md](platforms/fedora-wsl.md) — Fedora on WSL, Windows-side bootstrap, interop policy
- [platforms/macos.md](platforms/macos.md) — Apple Silicon macOS and AeroSpace
- [platforms/parrot-ctf.md](platforms/parrot-ctf.md) — the disposable Parrot Security Edition CTF guest

### Optional profiles

- [profiles/containers.md](profiles/containers.md) — rootless Podman
- [profiles/vm-host.md](profiles/vm-host.md) — KVM/QEMU + libvirt host
- [profiles/vm-guest.md](profiles/vm-guest.md) — Fedora guest integration
- [profiles/hardening.md](profiles/hardening.md) — conservative Fedora hardening
- [profiles/desktop-tools.md](profiles/desktop-tools.md) — day-to-day desktop applications
- [profiles/tailscale.md](profiles/tailscale.md) — Tailscale networking
- [profiles/ai.md](profiles/ai.md) — the AI-assisted development toolchain

### Workflows

- [workflows/install.md](workflows/install.md) — quick start, installer behavior, post-install checklist
- [workflows/first-run.md](workflows/first-run.md) — the choices the installer will not make for you
- [workflows/rerun.md](workflows/rerun.md) — `--rerun` and the last-known-good model
- [workflows/verification.md](workflows/verification.md) — `./doctor`, the platform verifiers, and what they prove
- [workflows/theming.md](workflows/theming.md) — Catppuccin, the `theme` command, generated Starship configs
- [workflows/shell.md](workflows/shell.md) — Zsh startup, PATH policy, ergonomics
- [workflows/terminal.md](workflows/terminal.md) — Ghostty and tmux
- [workflows/git.md](workflows/git.md) — Git and GitHub
- [workflows/editor.md](workflows/editor.md) — Neovim / LazyVim
- [workflows/development.md](workflows/development.md) — .NET, Angular/TypeScript, Python, OCaml, JSON, Markdown, smoke tests
- [workflows/latex.md](workflows/latex.md) — the LaTeX toolchain and editing workflow

### Reference

- [reference/installer-options.md](reference/installer-options.md) — generated option tables
- [reference/capability-matrix.md](reference/capability-matrix.md) — generated support/provider matrix
- [reference/verifiers.md](reference/verifiers.md) — generated per-platform verifier inventory
- [reference/keybindings.md](reference/keybindings.md) — the full keyboard and workflow reference
- [reference/defaults.md](reference/defaults.md) — what a default install ends up with
- [reference/git-identity.md](reference/git-identity.md) — machine-local Git identity and its migration
- [reference/licensing.md](reference/licensing.md) — the open licence decision
- [reference/third-party-notices.md](reference/third-party-notices.md) — vendored and fetched upstream material
- [cheatsheets/README.md](cheatsheets/README.md) — printable per-profile sheets

### Architecture and contracts

- [architecture/installation.md](architecture/installation.md) — ownership layers and the per-platform install flow
- [architecture/package-ownership.md](architecture/package-ownership.md) — which manager owns which tool
- [architecture/file-ownership.md](architecture/file-ownership.md) — Stow layout and machine-local state
- [architecture/repository-conventions.md](architecture/repository-conventions.md) — what must never be committed
- [capabilities.md](capabilities.md) — the capability/provider contract and how to change it
- [supply-chain.md](supply-chain.md) — provenance tiers and what is and is not claimed
- [supply-chain-sources.md](supply-chain-sources.md) — generated network-source inventory
- [testing.md](testing.md) — verification and installation-testing architecture
- [parrot-ctf-shell-audit.md](parrot-ctf-shell-audit.md) — source-by-source Parrot shell classification

### Troubleshooting

- [troubleshooting.md](troubleshooting.md) — start with `./doctor` (read-only;
  warnings exit `0`, failures exit `1`), then the entry matching the message
