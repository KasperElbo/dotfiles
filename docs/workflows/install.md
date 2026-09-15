# Installing and reinstalling

The full installation path for every platform: what to run, what the installer
will and will not decide for you, and what to do once it finishes. The
[README](../../README.md#quick-start) has the two-command version.

## Quick start

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

On a fresh Apple Silicon Mac, install Apple's Command Line Tools first, then
select the dedicated profile:

```bash
xcode-select --install
./install.sh --platform macos --dry-run
./install.sh --platform macos
```

The [macOS guide](../platforms/macos.md) covers permissions, AeroSpace keys,
multi-monitor behavior, deliberate defaults, development smoke tests, the
optional OCaml, Podman, Tailscale and AI profiles, which parts of the LaTeX
workflow macOS deliberately does not own, security, and rollback.

The installer makes Zsh the invoking user's default login shell on every
platform. Run `exec zsh -l` only when you want to replace the shell in the
current terminal immediately, rather than waiting for the next login. On
Fedora specifically, reboot after the first installation so Plasma, the
systemd user manager, and D-Bus discard the previous `SHELL` environment
value; Ghostty prefers that value over the account entry. See the
[Fedora-specific checklist steps](#fedora-specific-checklist-steps) below.

The default platform remains a normal Fedora workstation. From inside an
official Fedora WSL distribution, select the WSL variant explicitly:

```bash
./install.sh --platform fedora-wsl --dry-run
./install.sh --platform fedora-wsl --non-interactive
./install.sh --platform fedora-wsl --latex --non-interactive
```

From a Parrot Security Edition guest created on the reference Fedora VM host,
select the dedicated lab profile explicitly:

```bash
./install.sh --platform parrot-ctf --dry-run
./install.sh --platform parrot-ctf
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

ASUS laptop hardware support is explicitly opt-in:

```bash
./install.sh \
  --hardware ga402xz \
  --secure-boot \
  --charge-limit 80
```

The supported hardware profiles are `ga402xz` and `ga402rk`. The selected
profile is checked against the machine's DMI board name before any
model-specific packages are installed.

The keyboard-driven Sway session is also explicitly opt-in. It is installed
alongside Plasma, so the session can be selected at login without replacing
the dependable KDE fallback:

```bash
./install.sh --sway
```

The Fedora VM-host profile is also explicitly opt-in. It adds the native
KVM/QEMU + libvirt stack without changing the default workstation bootstrap:

```bash
./install.sh --vm-host
```

The same profile can be installed or validated independently:

```bash
./platforms/fedora/scripts/install-vm-host.sh
./platforms/fedora/scripts/verify-vm-host.sh --smoke-test
```

Inside a Fedora guest created by that host profile, reuse the normal bootstrap
and add only the explicit guest-integration profile:

```bash
./install.sh --vm-guest --kde --non-interactive
```

The guest profile is never selected automatically. It refuses bare metal and
does not allow the ASUS hardware profile to be combined with it.

The complete OCaml development environment is explicitly opt-in:

```bash
./install.sh --ocaml
```

## Installer options

Every option a machine can *remember* — its flag spelling, kind, default and
permitted values, per platform — is generated from
`config/install-options.tsv` into
[../reference/installer-options.md](../reference/installer-options.md). That is
the authoritative table; it is not repeated here, and the installer's own
`./install.sh --help` prints the same contract for this checkout.

What the table cannot express is the behaviour around those options:

**Options are rejected, never silently ignored.** Each platform's installer
accepts exactly the options its manifest declares. Passing a Fedora desktop,
Sway, VM or hardware flag to `--platform fedora-wsl` is an error, not a no-op.
`--tailscale` under `--platform fedora-wsl` gets its own dedicated rejection
message rather than the generic "unknown option" one; see
[Fedora WSL policy](../profiles/tailscale.md#fedora-wsl-policy) for why that
platform deliberately has no Tailscale node.

**The AI subcomponents require `--ai`.** `--codex`, `--firstmate`, `--gnhf`
and `--backpass` are rejected without it on every platform rather than being
silently ignored; `--backpass` does not additionally require `--firstmate`.
An installer run without `--ai` installs no Claude Code, Codex, Herdr, GNHF,
backpass, FirstMate or any tool `--firstmate` bundles. The profile is also
independently callable and safe to rerun through `./scripts/install-ai.sh`,
consistent with this repository's other component scripts. Read
[the AI profile guide](../profiles/ai.md) before enabling `--gnhf`, which runs
an agent unattended.

**Some options depend on another one being present.**
`--desktop-tools-force-defaults` requires `--desktop-tools`,
`--containers-api-socket` requires `--containers`, and `--secure-boot` and
`--charge-limit` require `--hardware`. Each is a focused error, checked before
anything is installed.

**`--containers` means something different on WSL.** It installs the same
Fedora profile, but with WSL-specific preconditions checked first; see
[Podman containers under WSL](../platforms/fedora-wsl.md#podman-containers-under-wsl).

**Execution controls apply to one run.** `--dry-run`, `--non-interactive`,
`--dev-workflows`, `--platform` and `-h/--help` are never remembered and never
replayed by [`--rerun`](rerun.md).

## The confirmation prompt

An interactive run resolves every option first — auto-detection, the theme
source, and any question the installer asks — then prints what it resolved and
asks once before it changes anything. On Fedora:

```text
Installation choices resolved.
Catppuccin flavour: macchiato (source: default — first-install default)
Continue with installation? [Y/n]
```

The other platforms print their own heading in place of the first line and ask
the same question; Parrot asks `Continue with the isolated lab profile?`
instead. Fedora asks one further question, before that summary, when
`--latex/--no-latex` was not given:

```text
Install LaTeX toolchain? [y/N]
```

The bracketed hint is the answer an empty line takes, so pressing Enter
continues the installation and declines the LaTeX toolchain. `y`, `yes`, `n`
and `no` are accepted in any case; anything else is rejected as unparseable
rather than guessed, and the run stops. Declining the installation prompt exits
with `Cancelled; no changes made.` before the first step runs, and a cancelled
run never replaces the machine's [remembered configuration](rerun.md).

`--non-interactive` asks nothing: every question resolves to the value the
options and defaults already imply, so the prompts above never appear. A run
whose standard input is closed — a CI job or a `nohup` with no terminal, and
without `--non-interactive` — declines rather than inheriting the default.

## Manual post-install checklist

After a fresh install, on every platform:

1. Configure `~/.config/git/local`.
2. Optionally configure `~/.config/git/drdk`.
3. Configure SSH authentication.
4. Configure optional SSH commit signing.
5. Run `gh auth login`.
6. Confirm Git identity:

   ```bash
   git config --show-origin --get user.name
   git config --show-origin --get user.email
   ```

7. If the optional AI profile (`--ai`) was selected, authenticate each
   installed tool interactively: run `claude` (and `codex`, if installed)
   and follow its login prompt; FirstMate uses the `gh auth login` from
   step 5. See [the AI profile guide](../profiles/ai.md).

8. Confirm GitHub SSH:

   ```bash
   ssh -T git@github.com
   ```

9. Confirm the selected theme:

   ```bash
   cat ~/.config/dotfiles/theme
   ```

10. Check what was recorded, and run the verifiers it names:

    ```bash
    ./doctor
    ```

    `./doctor` is a read-only summary of the recorded install; it names the
    verifier for every capability that was selected, and the verifiers do the
    real checking. See [verification](verification.md) for the full inventory
    and for what a failure versus a warning means.

### Fedora-specific checklist steps

These apply only to a Fedora or Fedora WSL desktop install; macOS has no
Plasma/Sway session and its login-shell change takes effect on the next login
without a required reboot (see [the macOS guide](../platforms/macos.md)).

1. Reboot after the initial installation so the desktop session observes the
   Zsh login-shell change. If an ASUS hardware profile also requested a
   reboot, use the same reboot; for the GA402XZ Secure Boot flow, complete
   MOK enrollment during it.
2. If Sway was installed, select it once at login and confirm the required
   outputs. Put any connector-specific rules in `~/.config/sway/local.conf`.
3. Run:

   ```bash
   ./platforms/fedora/scripts/verify.sh
   ```

   When a hardware profile is configured, this automatically includes its
   driver, service, DMI, and Secure Boot checks. For a focused rerun, use
   `./platforms/fedora/scripts/verify-asus-hardware.sh`.
