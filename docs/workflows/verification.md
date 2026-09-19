# Verification

Every install can be checked afterwards, and nothing in this path changes the
machine: the verifiers and `./doctor` are read-only.

## Start with `./doctor`

```bash
./doctor
```

`./doctor` is the cheap first step. It takes no options, reads the recorded
lifecycle state rather than the machine's packages, and reports what this
checkout believes was installed, whether the checkout still matches the
installed revision, whether each selected capability's state is intact, and
which verifier proves each of them. Warnings exit `0`; failures exit `1`.

It tells you *which* verifier to run next. This page is what those verifiers
prove.

## Running a verifier

Each platform has its own entry verifier, and the optional profiles that keep
their own state have their own:

```bash
./platforms/fedora/scripts/verify.sh
./platforms/fedora-wsl/scripts/verify.sh --latex
./platforms/macos/scripts/verify.sh --defaults --containers --tailscale --dictation
./platforms/parrot-ctf/scripts/verify.sh
```

[The generated verifier reference](../reference/verifiers.md) is the full
inventory: for every platform, which script proves which capabilities, and the
installer flags that select them. It is rendered from
`config/capabilities.tsv`, the same column `./doctor` reads, so it cannot drift
from what the installer actually ships.

Most verifiers take no arguments; they read the recorded lifecycle state and
check exactly the capabilities that were installed. Three take options, because
the state they would otherwise read is not theirs:

- `platforms/fedora-wsl/scripts/verify.sh --latex` also verifies the LaTeX
  toolchain, and `--dev-workflows` runs the language smoke tests.
- `platforms/macos/scripts/verify.sh` verifies the optional
  `--defaults`, `--containers`, `--tailscale` and `--dictation` areas only
  when asked.
- `scripts/test-dev-workflows.sh` is the `dev-workflows` verifier and selects
  languages with its own flags (see
  [the development workflow](development.md)).

On Fedora and Fedora WSL the platform verifier runs an optional profile's own
verifier whenever that profile's machine-local state exists, so one command
covers the whole machine; each profile verifier can also be run on its own. On
macOS the equivalent checks live in the same script, behind the flags above.

`scripts/verify.sh` is a deprecated compatibility wrapper for
`platforms/fedora/scripts/verify.sh`. It still forwards unchanged; use the
platform path.

## What a verifier proves

A verifier runs one section per capability that was installed, and stays silent
about capabilities that were not — it also confirms that an unselected optional
profile left nothing behind. The Fedora verifier is the broadest one, and its
sections are representative of all of them:

- the Fedora security baseline: SELinux enforcing, firewalld enabled and active, Secure
  Boot state (always, independent of `--hardening`)
- the Terra package trust root: the repository's effective `gpgcheck` and the
  pinned signing key in the RPM keyring, read-only and without `sudo` (always,
  because the bootstrap imports that key only once; see
  [the supply chain](../supply-chain.md))
- required core commands, each run as well as found on PATH, and the SFTP
  client baseline
- Stow-managed links, and nested Git repositories or generated junk files
- machine-local theme state, required theme assets, and the derived
  Ghostty/Delta/tmux theme overrides
- the login shell, the terminal, and Catppuccin tmux installation/version
- Git local configuration
- mise configuration and commands
- expected Mason editor tooling, warnings for untracked Mason packages, and
  Neovim startup/version
- each selected optional capability: KDE or Sway integration, the LaTeX
  toolchain, the OCaml switch and Platform tools, ASUS hardware, the VM host or
  guest, the hardening profile, desktop tools, containers, Tailscale, and the
  AI profile's tool ownership (see
  [the hardening profile guide](../profiles/hardening.md) and
  [the AI profile guide](../profiles/ai.md))

Missing essential components are failures; optional or editor-specific
omissions may be warnings, and a check the environment did not let the verifier
observe is reported as unobserved rather than as a pass. A verifier exits
non-zero only when it recorded a failure — warnings and unobserved checks exit
`0`, exactly like `./doctor`.

When a verifier fails, [troubleshooting](../troubleshooting.md) is the next
stop.

## Before opening a pull request

Verification is about one machine. Proving the repository itself is a different
job with different entry points:

```bash
./scripts/lint.sh
./scripts/test.sh
git diff --check
```

`./scripts/lint.sh` validates every tracked shell script and sourced fragment
with Bash and ShellCheck, and also checks the generated documentation, the
capability and action manifests, repository hygiene and the generated Starship
configurations. It requires both `shellcheck` and `python3`.

[The testing architecture](../testing.md) owns the rest: what each suite
covers, what the mocks guarantee, and which jobs CI runs.
