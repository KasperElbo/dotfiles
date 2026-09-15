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

The installer makes Zsh the invoking user's default login shell. Reboot after
the first installation so Plasma, the systemd user manager, and D-Bus discard
the previous `SHELL` environment value; Ghostty prefers that value over the
account entry. Run `exec zsh -l` only when you want to replace the shell in the
current terminal before rebooting.

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
independently callable and safe to rerun through `common/install-ai.sh`,
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

## Manual post-install checklist

After a fresh install:

1. Configure `~/.config/git/local`.
2. Optionally configure `~/.config/git/drdk`.
3. Configure SSH authentication.
4. Configure optional SSH commit signing.
5. Run `gh auth login`.
6. Reboot after the initial installation so the desktop session observes the
   Zsh login-shell change. If an ASUS hardware profile also requested a reboot,
   use the same reboot; for the GA402XZ Secure Boot flow, complete MOK
   enrollment during it.
7. If Sway was installed, select it once at login and confirm the required
   outputs. Put any connector-specific rules in `~/.config/sway/local.conf`.

8. Run:

   ```bash
   ./platforms/fedora/scripts/verify.sh
   ```

   When a hardware profile is configured, this automatically includes its
   driver, service, DMI, and Secure Boot checks. For a focused rerun, use
   `./platforms/fedora/scripts/verify-asus-hardware.sh`.

9. Confirm Git identity:

   ```bash
   git config --show-origin --get user.name
   git config --show-origin --get user.email
   ```

10. If the optional AI profile (`--ai`) was selected, authenticate each
    installed tool interactively: run `claude` (and `codex`, if installed)
    and follow its login prompt; FirstMate uses the `gh auth login` from
    step 5. See [the AI profile guide](../profiles/ai.md).

11. Confirm GitHub SSH:

   ```bash
   ssh -T git@github.com
   ```

12. Confirm the selected theme:

    ```bash
    cat ~/.config/dotfiles/theme
    ```
