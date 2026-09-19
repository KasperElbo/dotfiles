# Generated verifier reference

Generated from `config/capabilities.tsv`; do not edit these tables by hand.

Each row is one verifier script, the capabilities it proves on that
platform, and the installer flags that select those capabilities. The flags
are what an install asks for — not arguments to the verifier: most verifiers
read the recorded lifecycle state instead of taking options. See
[the verification workflow](../workflows/verification.md) for the few that do
take arguments, and for what a failure versus a warning means.

A capability with no row here is not verified on that platform because it is
not supported there; [the capability matrix](capability-matrix.md) says which
platforms support what, and who owns each deliberate absence.

## Fedora

| Verifier | Capabilities it proves | Selected by |
|---|---|---|
| `common/verify-ai.sh` | `ai`, `backpass`, `codex`, `firstmate`, `gnhf` | `--ai`, `--backpass`, `--codex`, `--firstmate`, `--gnhf` |
| `common/verify-ocaml.sh` | `ocaml` | `--ocaml` |
| `platforms/fedora/scripts/verify-asus-hardware.sh` | `hardware` | `--hardware` |
| `platforms/fedora/scripts/verify-containers.sh` | `containers` | `--containers` |
| `platforms/fedora/scripts/verify-desktop-tools.sh` | `desktop-tools` | `--desktop-tools` |
| `platforms/fedora/scripts/verify-hardening.sh` | `hardening` | `--hardening` |
| `platforms/fedora/scripts/verify-tailscale.sh` | `tailscale` | `--tailscale` |
| `platforms/fedora/scripts/verify-vm-guest.sh` | `vm-guest` | `--vm-guest` |
| `platforms/fedora/scripts/verify-vm-host.sh` | `vm-host` | `--vm-host` |
| `platforms/fedora/scripts/verify.sh` | `base`, `dotnet-debug`, `kde`, `latex`, `sway`, `terminal` | `--kde`, `--latex`, `--sway` |
| `scripts/test-dev-workflows.sh` | `dev-workflows` | `--dev-workflows` |

## Fedora WSL

| Verifier | Capabilities it proves | Selected by |
|---|---|---|
| `common/verify-ai.sh` | `ai`, `backpass`, `codex`, `firstmate`, `gnhf` | `--ai`, `--backpass`, `--codex`, `--firstmate`, `--gnhf` |
| `common/verify-ocaml.sh` | `ocaml` | `--ocaml` |
| `platforms/fedora-wsl/scripts/verify-containers.sh` | `containers` | `--containers` |
| `platforms/fedora-wsl/scripts/verify.sh` | `base`, `dotnet-debug`, `latex` | `--latex` |
| `scripts/test-dev-workflows.sh` | `dev-workflows` | `--dev-workflows` |

## macOS

| Verifier | Capabilities it proves | Selected by |
|---|---|---|
| `common/verify-ai.sh` | `ai`, `backpass`, `codex`, `firstmate`, `gnhf` | `--ai`, `--backpass`, `--codex`, `--firstmate`, `--gnhf` |
| `common/verify-ocaml.sh` | `ocaml` | `--ocaml` |
| `platforms/macos/scripts/verify.sh` | `base`, `containers`, `dictation`, `dotnet-debug`, `tailscale`, `terminal` | `--containers`, `--dictation`, `--tailscale` |
| `scripts/test-dev-workflows.sh` | `dev-workflows` | `--dev-workflows` |

## Parrot CTF

| Verifier | Capabilities it proves | Selected by |
|---|---|---|
| `platforms/parrot-ctf/scripts/verify.sh` | `base`, `terminal`, `vm-guest` | always installed |
