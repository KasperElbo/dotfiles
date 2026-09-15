# Installer options

Generated from `config/install-options.tsv`; do not edit these tables by
hand. Run `./scripts/render-installer-options.py` after changing the manifest.

That manifest is the single source for every option this machine can
*remember*: the installer's parser, the `--rerun` selection record and these
tables all read it. An option missing from a platform's table below is one
that platform's installer rejects rather than silently ignores.

`Default` is what the option resolves to when it is not given. `auto` means
the installer detects or asks; see the platform guide for which.

## Fedora workstation (`--platform fedora`, the default)

Platform guide: [../platforms/fedora.md](../platforms/fedora.md)

| Option | Enable | Disable | Default | Values | Summary | Capability | Documented in |
|---|---|---|---|---|---|---|---|
| `theme` | `--theme` | — | `macchiato` | `latte\|frappe\|macchiato\|mocha` | Catppuccin flavour | — | — |
| `kde` | `--kde` | `--no-kde` | `false` | — | KDE integration | `kde` | [docs/workflows/theming.md](../workflows/theming.md#kde) |
| `latex` | `--latex` | `--no-latex` | `false` | — | LaTeX toolchain | `latex` | [docs/workflows/latex.md](../workflows/latex.md#latex-editing-workflow) |
| `ocaml` | `--ocaml` | `--no-ocaml` | `false` | — | OCaml profile | `ocaml` | [docs/workflows/development.md](../workflows/development.md#ocaml-development) |
| `sway` | `--sway` | `--no-sway` | `false` | — | Sway session | `sway` | [docs/platforms/fedora.md](../platforms/fedora.md#optional-sway-session) |
| `vm-host` | `--vm-host` | — | `false` | — | KVM/QEMU + libvirt host profile | `vm-host` | [docs/profiles/vm-host.md](../profiles/vm-host.md) |
| `vm-guest` | `--vm-guest` | — | `false` | — | Explicit KVM/QEMU guest profile | `vm-guest` | [docs/profiles/vm-guest.md](../profiles/vm-guest.md) |
| `hardening` | `--hardening` | `--no-hardening` | `false` | — | Security-hardening profile | `hardening` | [docs/profiles/hardening.md](../profiles/hardening.md) |
| `desktop-tools` | `--desktop-tools` | `--no-desktop-tools` | `false` | — | Desktop application profile | `desktop-tools` | [docs/profiles/desktop-tools.md](../profiles/desktop-tools.md) |
| `desktop-tools-force-defaults` | `--desktop-tools-force-defaults` | — | `false` | — | Override existing application defaults | — | — |
| `containers` | `--containers` | `--no-containers` | `false` | — | Rootless Podman profile | `containers` | [docs/profiles/containers.md](../profiles/containers.md) |
| `containers-api-socket` | `--containers-api-socket` | — | `false` | — | Rootless Podman API socket | — | — |
| `tailscale` | `--tailscale` | `--no-tailscale` | `false` | — | Tailscale networking profile | `tailscale` | [docs/profiles/tailscale.md](../profiles/tailscale.md) |
| `ai` | `--ai` | `--no-ai` | `false` | — | AI-assisted development profile | `ai` | [docs/profiles/ai.md](../profiles/ai.md) |
| `codex` | `--codex` | `--no-codex` | `inherit` | — | AI subcomponent: Codex CLI | `codex` | [docs/profiles/ai.md](../profiles/ai.md) |
| `firstmate` | `--firstmate` | `--no-firstmate` | `inherit` | — | AI subcomponent: FirstMate toolchain | `firstmate` | [docs/profiles/ai.md](../profiles/ai.md) |
| `gnhf` | `--gnhf` | `--no-gnhf` | `inherit` | — | AI subcomponent: GNHF | `gnhf` | [docs/profiles/ai.md](../profiles/ai.md) |
| `backpass` | `--backpass` | `--no-backpass` | `inherit` | — | AI subcomponent: backpass | `backpass` | [docs/profiles/ai.md](../profiles/ai.md) |
| `hardware` | `--hardware` | — | — | `ga402xz\|ga402rk` | ASUS hardware model | `hardware` | [docs/platforms/fedora.md](../platforms/fedora.md#asus-laptop-hardware) |
| `secure-boot` | `--secure-boot` | — | `false` | — | Require Secure Boot for the selected hardware | — | — |
| `charge-limit` | `--charge-limit` | — | — | `[4-9][0-9]\|100` | ASUS battery charge limit | — | — |

## Fedora on WSL (`--platform fedora-wsl`)

Platform guide: [../platforms/fedora-wsl.md](../platforms/fedora-wsl.md)

| Option | Enable | Disable | Default | Values | Summary | Capability | Documented in |
|---|---|---|---|---|---|---|---|
| `theme` | `--theme` | — | `macchiato` | `latte\|frappe\|macchiato\|mocha` | Catppuccin flavour | — | — |
| `ocaml` | `--ocaml` | `--no-ocaml` | `false` | — | OCaml profile | `ocaml` | [docs/workflows/development.md](../workflows/development.md#ocaml-development) |
| `latex` | `--latex` | `--no-latex` | `false` | — | LaTeX toolchain | `latex` | [docs/workflows/latex.md](../workflows/latex.md#latex-editing-workflow) |
| `containers` | `--containers` | `--no-containers` | `false` | — | Rootless Podman profile | `containers` | [docs/profiles/containers.md](../profiles/containers.md) |
| `containers-api-socket` | `--containers-api-socket` | — | `false` | — | Rootless Podman API socket | — | — |
| `ai` | `--ai` | `--no-ai` | `false` | — | AI-assisted development profile | `ai` | [docs/profiles/ai.md](../profiles/ai.md) |
| `codex` | `--codex` | `--no-codex` | `inherit` | — | AI subcomponent: Codex CLI | `codex` | [docs/profiles/ai.md](../profiles/ai.md) |
| `firstmate` | `--firstmate` | `--no-firstmate` | `inherit` | — | AI subcomponent: FirstMate toolchain | `firstmate` | [docs/profiles/ai.md](../profiles/ai.md) |
| `gnhf` | `--gnhf` | `--no-gnhf` | `inherit` | — | AI subcomponent: GNHF | `gnhf` | [docs/profiles/ai.md](../profiles/ai.md) |
| `backpass` | `--backpass` | `--no-backpass` | `inherit` | — | AI subcomponent: backpass | `backpass` | [docs/profiles/ai.md](../profiles/ai.md) |

## Apple Silicon macOS (`--platform macos`)

Platform guide: [../platforms/macos.md](../platforms/macos.md)

| Option | Enable | Disable | Default | Values | Summary | Capability | Documented in |
|---|---|---|---|---|---|---|---|
| `theme` | `--theme` | — | `macchiato` | `latte\|frappe\|macchiato\|mocha` | Catppuccin flavour | — | — |
| `ocaml` | `--ocaml` | `--no-ocaml` | `false` | — | OCaml profile | `ocaml` | [docs/workflows/development.md](../workflows/development.md#ocaml-development) |
| `containers` | `--containers` | `--no-containers` | `false` | — | Podman machine profile | `containers` | [docs/profiles/containers.md](../profiles/containers.md) |
| `tailscale` | `--tailscale` | `--no-tailscale` | `false` | — | Tailscale networking profile | `tailscale` | [docs/profiles/tailscale.md](../profiles/tailscale.md) |
| `defaults` | `--defaults` | `--no-defaults` | `true` | — | Reversible macOS defaults | — | — |
| `ai` | `--ai` | `--no-ai` | `false` | — | AI-assisted development profile | `ai` | [docs/platforms/macos.md](../platforms/macos.md#ai-assisted-development-toolchain) |
| `codex` | `--codex` | `--no-codex` | `inherit` | — | AI subcomponent: Codex CLI | `codex` | [docs/platforms/macos.md](../platforms/macos.md#ai-assisted-development-toolchain) |
| `firstmate` | `--firstmate` | `--no-firstmate` | `inherit` | — | AI subcomponent: FirstMate toolchain | `firstmate` | [docs/platforms/macos.md](../platforms/macos.md#ai-assisted-development-toolchain) |
| `gnhf` | `--gnhf` | `--no-gnhf` | `inherit` | — | AI subcomponent: GNHF | `gnhf` | [docs/platforms/macos.md](../platforms/macos.md#ai-assisted-development-toolchain) |
| `backpass` | `--backpass` | `--no-backpass` | `inherit` | — | AI subcomponent: backpass | `backpass` | [docs/platforms/macos.md](../platforms/macos.md#ai-assisted-development-toolchain) |

## Parrot Security Edition CTF guest (`--platform parrot-ctf`)

Platform guide: [../platforms/parrot-ctf.md](../platforms/parrot-ctf.md)

| Option | Enable | Disable | Default | Values | Summary | Capability | Documented in |
|---|---|---|---|---|---|---|---|
| `theme` | `--theme` | — | `macchiato` | `latte\|frappe\|macchiato\|mocha` | Catppuccin flavour | — | — |

## Execution controls

These control one invocation and are never part of the remembered
configuration, so they have no manifest row. `./install.sh --help` prints the
authoritative list for this checkout.

| Control | Meaning |
|---|---|
| `--platform PLATFORM` | Select the platform installer: `fedora` (default), `fedora-wsl`, `macos`, `parrot-ctf`. |
| `--rerun` | Reapply this machine's last successful configuration. See [rerun.md](../workflows/rerun.md). |
| `--dry-run` | Resolve and print the plan; change nothing. |
| `--non-interactive` | Use defaults without prompting; requires cached sudo where sudo is needed. |
| `--dev-workflows` | Run the disposable development-workflow smoke tests after installing. |
| `-h`, `--help` | Print the platform installer's own help, which is authoritative for this checkout. |
