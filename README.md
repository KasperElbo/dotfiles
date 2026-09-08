# Development and Security-Lab Dotfiles

Opinionated, reproducible dotfiles for a keyboard-driven development workstation built around:

- Fedora
- Fedora on WSL, with Windows as the desktop and terminal host
- Apple Silicon macOS with an AeroSpace keyboard-first desktop
- Parrot Security Edition in a disposable KVM/QEMU CTF guest
- KDE Plasma / Wayland, with an optional Sway session
- Ghostty
- Zsh
- Neovim + LazyVim
- tmux
- Git + GitHub CLI + Lazygit
- mise-managed language runtimes
- an optional opam-managed OCaml environment
- Catppuccin across the desktop, terminal, editor, and CLI tools

The configuration is intended to stay close to upstream defaults. Custom behavior is added only where it solves a concrete workflow problem.

The current default Catppuccin flavor is **Macchiato** with the **Mauve** accent.

## Design principles

1. **Use the native package manager for machine-level tools.** Fedora/DNF,
   Parrot/APT, or native Apple Silicon Homebrew owns operating-system and
   integrated tools.
2. **Use mise for general language runtimes and portable developer CLIs.**
   Ecosystems with their own switch model, such as OCaml/opam, remain with
   their native manager.
3. **Use Mason only for Neovim-specific tooling.** Tooling that must match a
   language environment stays with that environment.
4. **Keep project tooling in the project.** CSharpier, Prettier, ESLint, `dotnet-ef`, TypeScript, etc. should normally be declared by the repository that uses them.
5. **Keep shared configuration tracked and user-specific state local.**
6. **Prefer upstream workflows over custom glue.**

---

# Supported environment

The workstation configuration has been developed and tested on:

- Fedora 44
- macOS Tahoe 26 on Apple Silicon (`arm64`)
- KDE Plasma on Wayland
- Sway on Wayland when installed with `--sway`
- Zsh
- Ghostty
- Neovim 0.12+
- GNU Stow

The optional guest profiles target Fedora 44 and Parrot Security Edition 7.3
KVM/QEMU guests managed by libvirt, with virt-manager as the normal graphical
client. Parrot is a CTF/lab guest, not a general-purpose workstation target.

The supported bootstraps are a normal Fedora workstation and the official
Fedora distribution running under WSL 2. The WSL variant is a Linux development
runtime: it deliberately does not reproduce the Fedora desktop, laptop, GPU or
virtualization-host setup inside WSL.

The macOS bootstrap targets `/opt/homebrew` on Apple Silicon and uses AeroSpace
for a Sway-like nine-workspace model without disabling SIP. See the complete
[Apple Silicon macOS workstation guide](docs/macos.md).

---

# Quick start

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

The [macOS guide](docs/macos.md) covers permissions, AeroSpace keys,
multi-monitor behavior, deliberate defaults, development smoke tests, optional
OCaml/Podman profiles, security, and rollback.

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
./scripts/install-vm-host.sh
./scripts/verify-vm-host.sh --smoke-test
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

```text
--platform PLATFORM fedora (default) | fedora-wsl | macos | parrot-ctf

--theme FLAVOUR    latte | frappe | macchiato | mocha
                   default: macchiato

--kde              install Catppuccin KDE integration
--no-kde           skip KDE integration

--latex            install the LaTeX toolchain
--no-latex         skip the LaTeX toolchain

--ocaml            install the optional OCaml development profile
--no-ocaml         skip the OCaml profile (default)

--sway             install the optional keyboard-driven Sway session
--no-sway          skip Sway (default)

--vm-host          install the optional KVM/QEMU + libvirt VM-host profile

--vm-guest         install QEMU/SPICE agents inside an explicit Fedora guest

--hardening        install the optional conservative security-hardening profile
--no-hardening     skip the hardening profile (default)
--desktop-tools    install the optional day-to-day desktop application profile
--no-desktop-tools skip the desktop-tools profile (default)
--desktop-tools-force-defaults
                   with --desktop-tools, override existing default
                   applications for the mimetypes it manages instead of
                   leaving an existing choice alone (default: leave alone)

--containers       install the optional rootless Podman container
                   development profile
--no-containers    skip the containers profile (default)
--containers-api-socket
                   with --containers, enable the rootless, socket-activated
                   Podman API socket for Docker-compatible client tooling
                   (default: disabled)

--tailscale        install the optional Tailscale networking profile
                   (tailscale CLI + tailscaled); never runs 'tailscale up'
                   or embeds credentials/tailnet policy
--no-tailscale     skip the Tailscale profile (default)

--ai               install the optional AI-assisted development profile:
                   Claude Code and Herdr (see "AI-assisted development
                   toolchain" below)
--no-ai            skip the AI profile (default)
--codex            with --ai, also install the OpenAI Codex CLI
--no-codex         skip Codex (default)
--firstmate        with --ai, also install FirstMate and every tool its own
                   docs list as required: Treehouse, No Mistakes, gh-axi,
                   chrome-devtools-axi, lavish-axi, tasks-axi, quota-axi
                   (see "Optional: FirstMate and its required toolchain"
                   below)
--no-firstmate     skip FirstMate and its toolchain (default)
--gnhf             with --ai, also install GNHF, an unattended overnight
                   agent orchestrator (read "Optional: GNHF" below before
                   use; it runs an agent unsupervised)
--no-gnhf          skip GNHF (default)
--backpass         with --ai, also install backpass, which proposes
                   evidence-backed AGENTS.md/CLAUDE.md edits from agent
                   session transcripts, gated behind mandatory human
                   review (independent of --firstmate; see "Optional:
                   backpass" below)
--no-backpass      skip backpass (default)

--hardware MODEL   install ASUS hardware support for ga402xz or ga402rk
                   default: disabled
--secure-boot      require Secure Boot for the selected hardware profile
--charge-limit N   set ASUS battery charge limit (40-100 percent)

--dry-run          print the installation plan only
--non-interactive  use defaults without prompting

-h, --help         show help
```

The Fedora WSL installer exposes `--theme`, `--ocaml`, `--latex`,
`--containers`, `--containers-api-socket`, `--ai`, `--codex`, `--firstmate`,
`--gnhf`, `--backpass`, `--smoke-test`, `--dry-run`, and `--non-interactive`.
Fedora desktop, Sway, VM and hardware flags are rejected rather than
silently ignored; see "Podman containers under WSL" below for what
`--containers` actually requires and changes on this platform, and
"AI-assisted development toolchain" for `--ai`. `--tailscale` gets its own
explicit, dedicated rejection message rather than the generic "unknown
option" one; see "Optional Tailscale networking profile" > "Fedora WSL
policy" for why.

`--codex`, `--firstmate`, `--gnhf`, and `--backpass` require `--ai` on every
platform; the installer rejects them otherwise instead of silently ignoring
them (`--backpass` does not additionally require `--firstmate`). Running
any installer without `--ai` installs no Claude Code, Codex, Herdr, GNHF,
backpass, FirstMate, or any of the tools `--firstmate` bundles (Treehouse,
No Mistakes, gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi, quota-axi);
`--ai` and its subcomponents are also independently callable and safe to
rerun through `common/install-ai.sh` (or `./scripts/install-ai.sh`),
consistent with this repository's other
component scripts.

---

# Fedora on WSL

The WSL variant treats Noctty (or another Windows terminal) and the Windows
desktop as the host UI. Fedora owns the shell and all development commands. It
composes the same Zsh, Git, Neovim/LazyVim, tmux, mise, Starship, fzf, Lazygit
and language configuration used by the normal Fedora workstation.

## Windows-side prerequisites

From a normal, non-administrator PowerShell session in this checkout, preview
and run the Windows-side bootstrap:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\platforms\windows\install.ps1 -DryRun
.\platforms\windows\install.ps1
```

Use Windows 11 or a supported Windows 10 build with current WSL updates.
Noctty additionally requires OpenGL 4.3-capable graphics; the script does not
remove or replace any terminal already installed on Windows.

The script discovers the newest official `FedoraLinux` name advertised by WSL,
prompts for elevation only for WSL installation or conversion, and installs
Noctty for the current user through its official Scoop bucket. It is safe to
run again: an installed Fedora WSL 2 distribution and Noctty are retained, and
only the script's marked Noctty configuration block is updated. That block
loads the synchronized `ghostty/.config/ghostty/shared.conf`, which is also
included by Ghostty on Fedora, so shared terminal settings remain in one
tracked place. The shared config and Catppuccin theme files are copied into a
managed area below Noctty's Windows config directory. Rerun the Windows script
after updating the dotfiles checkout to synchronize changes; Noctty does not
depend on that checkout remaining at the same path.

If the Store-backed `wsl --list --online` output does not show Fedora, the
script falls back to Microsoft's published WSL distribution catalogue and uses
`wsl --install --web-download`. This keeps discovery dynamic without requiring
the Fedora image to be available through the Microsoft Store catalogue.

Useful options are:

```powershell
# Select an exact name shown by `wsl --list --online`.
.\platforms\windows\install.ps1 -FedoraDistribution FedoraLinux-<version>

# Install Fedora WSL without installing Noctty.
.\platforms\windows\install.ps1 -SkipNoctty

# Install Noctty but preserve all of its existing configuration.
.\platforms\windows\install.ps1 -SkipNocttyConfiguration
```

If Noctty already has a user-managed `command =` setting, the script retains
it and omits the managed Fedora command. Otherwise the marked block in
`%LOCALAPPDATA%\noctty\config.ghostty` starts the selected Fedora distribution.
User-authored Noctty settings remain below the block and therefore stay
separate from the shared Ghostty source. Noctty is still a young project, so
keep another working Windows terminal available while evaluating it.

Theme switching works from inside Fedora WSL using the same command as a
normal workstation:

```bash
theme latte
theme frappe
theme macchiato
theme mocha
```

The WSL-only hook updates Noctty's managed `dotfiles/theme.conf` through an
explicit Windows PowerShell path. Press `Ctrl+Shift+,` in a running Noctty
instance to reload the configuration; otherwise the selection applies on its
next launch. A user-authored `theme =` setting later in
`%LOCALAPPDATA%\noctty\config.ghostty` deliberately takes precedence over this
managed selection.

To perform the WSL portion manually instead, use an elevated PowerShell:

```powershell
wsl --update
wsl --set-default-version 2
wsl --list --online | findstr /I Fedora
wsl --install -d <Fedora-name-shown-by-the-previous-command>
wsl --list --verbose
```

Using the name returned by `wsl --list --online` avoids tying the repository to
a Fedora Store image name that changes with releases. Complete the Fedora
first-launch user setup with `wsl --distribution <Fedora-name>`, then clone this
repository from inside Fedora:

```bash
sudo dnf upgrade --refresh
mkdir -p ~/src
git clone <REPOSITORY_URL> ~/src/dotfiles
cd ~/src/dotfiles
./install.sh --platform fedora-wsl --dry-run
./install.sh --platform fedora-wsl
```

The installer makes Zsh the user's default login shell. Run `exec zsh -l`
after installation to replace the Bash process in the current terminal; new
WSL sessions start Zsh automatically.

Keep repositories under the WSL Linux filesystem, normally `~/src`. `/mnt/c`
is useful for exchanging files with Windows, but its metadata, file-watching,
case-sensitivity and I/O behavior make it a poor default for Git repositories,
Node dependency trees and build output.

## PATH and Windows interoperability

Windows commonly appends its PATH to a WSL process. This can make a missing
Linux command silently resolve to `node.exe`, `dotnet.exe`, `python.exe` or a
Windows-installed `codex`. The WSL platform hook removes `/mnt/<drive>/...`
entries before `.zshrc` executes any tools. mise then activates only the
Linux-native runtimes installed inside Fedora.

This profile treats "no Windows directories in `PATH`" and "explicit Windows
executables still run" as two independent properties (issue #104), each
controlled by its own `/etc/wsl.conf` `[interop]` key, and enforces both:

```ini
[interop]
enabled=true
appendWindowsPath=false
```

`appendWindowsPath=false` is what keeps Windows directories out of `PATH` at
the WSL level, ahead of and independent from the `.zshrc` PATH-stripping hook
above. `enabled=true` is the one this profile actually needs kept **on**: it
is what lets an explicitly full-pathed Windows executable — `wsl-open`, the
clipboard helpers, Windows OpenSSH, a Windows-hosted 1Password SSH agent —
run at all. Setting `enabled=false` (or omitting `[interop]` on some
WSL/Fedora image combinations) breaks that explicit path even though `PATH`
itself stays clean; it fails as a plain "cannot execute binary file" /
"exec format error" from the shell, not an obviously WSL-related message.

`./install.sh --platform fedora-wsl` keeps this policy in place
automatically on every run, merge-safe:

```bash
platforms/fedora-wsl/scripts/configure-interop.sh
platforms/fedora-wsl/scripts/configure-interop.sh --dry-run
```

It edits only the `[interop]` section's `enabled` and `appendWindowsPath`
keys — every other section and key already in `/etc/wsl.conf`, including an
existing `[boot] systemd=true` (see "systemd" below) or another WSL
distribution's unrelated settings, is left untouched; it never replaces the
whole file. Rerunning it is a no-op once the policy is already in place (it
does not touch the file or invoke `sudo` again), and `--dry-run` shows the
resulting file without changing anything. A WSL restart is required before
either key actually takes effect, so both the installer and the standalone
script end with a reminder to run this from Windows PowerShell — note that
it affects **every** WSL distribution on the machine, not just this one:

```powershell
wsl --shutdown
```

Windows interoperability remains available deliberately through absolute-path
helpers rather than through every Windows executable being on `PATH`:

| Helper | Purpose |
|---|---|
| `wsl-copy` | Send standard input to the Windows clipboard |
| `wsl-paste` | Write the Windows clipboard to standard output |
| `wsl-open URL_OR_PATH` | Open a URL or file with its Windows handler |

`BROWSER=wsl-open` lets Linux-native tools such as `gh auth login --web` open
the Windows browser. Set `WINDOWS_SYSTEM_ROOT` only if Windows is not available
at the conventional `/mnt/c/Windows` mount. Neovim's `"+` and `"*` registers
use the same clipboard helpers through a WSL-only LazyVim plugin spec.

`verify.sh`'s "Windows executable interop" section checks the two properties
separately: the existing Zsh-PATH and per-command checks confirm no Windows
directory has leaked into `PATH`, and a dedicated check actually runs
`/mnt/c/Windows/System32/cmd.exe /c echo interop-ok` and confirms it prints
`interop-ok`, rather than trusting `PATH` cleanliness alone or a single
binfmt handler name (WSL/runtime versions have used more than one). It also
reports whatever `WSLInterop*` entries it finds under
`/proc/sys/fs/binfmt_misc` as an informational hint, never as the sole basis
for pass/fail. If the behavioral check fails, it prints the exact
`/etc/wsl.conf` `[interop]` block above and the `wsl --shutdown` reminder,
not just "broken."

## systemd

The current command-line profile does not require services, so lack of systemd
is reported as a warning rather than causing installation to fail. If a later
profile or a project needs system services, verify PID 1 first:

```bash
ps -p 1 -o comm=
systemctl is-system-running
```

If the first command is not `systemd`, merge the following into
`/etc/wsl.conf`, then run `wsl --shutdown` from PowerShell:

```ini
[boot]
systemd=true
```

Do not enable it merely to satisfy this dotfiles profile. The optional
containers profile below is the one profile in this WSL variant that does
require it. `[boot] systemd=true` is a separate, unrelated `/etc/wsl.conf`
section from the `[interop]` policy in "PATH and Windows interoperability"
above — `configure-interop.sh` only ever touches `[interop]`, so an existing
`[boot] systemd=true` (or lack of one) is preserved exactly as-is either
way.

## Podman containers under WSL

`--containers` (issue #93, building on #89's native Fedora profile) is
supported on Fedora WSL, with WSL-specific preconditions checked explicitly
before anything is installed:

```bash
./install.sh --platform fedora-wsl --containers
./install.sh --platform fedora-wsl --containers --containers-api-socket
```

or standalone, after the base WSL profile is installed:

```bash
platforms/fedora-wsl/scripts/install-containers.sh
platforms/fedora-wsl/scripts/install-containers.sh --dry-run
platforms/fedora-wsl/scripts/verify-containers.sh
```

All of the actual work — installing `podman`/`podman-compose`, allocating a
subuid/subgid range, the rootless API socket, and the pull/run/build/bind
mount/named volume/localhost port/container-network/Compose verification —
is Fedora's own `platforms/fedora/scripts/install-containers.sh` and
`verify-containers.sh`, reused completely unchanged: none of that logic is
actually WSL-specific. What WSL genuinely changes is the *preconditions*
those scripts are allowed to assume, so a thin WSL wrapper
(`platforms/fedora-wsl/scripts/install-containers.sh`,
`platforms/fedora-wsl/lib/containers.sh`) checks those explicitly instead of
silently reusing or silently branching:

- **systemd as PID 1 is a hard requirement for this profile only** — unlike
  the rest of the Fedora WSL variant, where systemd is optional (see
  "systemd" above) — but PID 1 alone is not sufficient, confirmed against a
  real Fedora WSL run: WSL does not open a full login/PAM session by
  default, so nothing starts a `systemd --user` instance for your account
  even with `systemd=true` set, and `podman.socket` and rootless Podman's
  cgroup v2 delegation both need that instance's D-Bus session bus
  (`$XDG_RUNTIME_DIR/bus`). Without it, Podman falls back to
  `--cgroup-manager=cgroupfs` and cannot track the pause process it keeps
  to hold a rootless container network namespace alive — `podman version`/
  `info`, pulls, plain runs, bind mounts, and named volumes all keep
  working, but `podman network create`, a build that runs the built image,
  and Compose all fail. Fix it once with:

  ```bash
  sudo loginctl enable-linger "$(id -un)"
  ```

  then restart the WSL distribution (`wsl --terminate <DistroName>` from
  Windows PowerShell, then reopen it) so the linger setting takes effect.
  Both `install-containers.sh` and `verify-containers.sh` check for
  systemd as PID 1 *and* this reachable user session, and refuse to
  continue (or report a failure) with this exact remediation before making
  any change or running the smoke test, rather than only checking PID 1
  and leaving a partially-broken install to fail confusingly mid-smoke-test.
- **cgroup v2 and unprivileged user namespaces are checked directly**, by
  testing for `/sys/fs/cgroup/cgroup.controllers` and a positive
  `/proc/sys/user/max_user_namespaces`, rather than by guessing from a
  kernel version string. Both have shipped by default in Microsoft's WSL2
  kernel for years; if either check fails, update the kernel from Windows
  PowerShell with `wsl --update` and retry.
- **`--dry-run` stays mutation-free regardless of whether the preconditions
  above are currently met** (consistent with every other profile in this
  repository): it prints the WSL preflight requirements and Fedora's own
  containers plan without checking or changing anything.

### Networking mode

WSL2's default NAT networking and the newer mirrored networking mode (see
"DNS, VPN and networking" above) only change how Windows reaches a port
published inside WSL; they do not change Podman's own rootless container
network. netavark/aardvark-dns, pasta/slirp4netns, and container-to-container
DNS resolution on a `podman network create`d network are entirely internal
to this WSL instance's Linux network namespace in both modes.
`verify-containers.sh` reports which pattern it observed (a single
non-loopback interface, consistent with NAT, versus more than one,
consistent with mirrored) as an informational hint, not a gate — it cannot
reliably tell the two apart, and does not need to, since neither one blocks
the profile.

**Localhost port publishing** (`-p 127.0.0.1:PORT:...`) is reachable from
Windows at `http://localhost:PORT/` through WSL2's built-in
Windows-to-Linux localhost forwarding, the same mechanism any other WSL
service on a loopback or wildcard bind already relies on. This is expected
to work under both NAT and mirrored networking; if it does not on a given
Windows build, treat it as a WSL networking-mode issue to diagnose with the
guidance in "DNS, VPN and networking" above, not a Podman problem.

### Bind mounts

Run containers and bind-mount from repositories in the WSL Linux filesystem
(`~/src`, matching this repository's general WSL guidance), the same way
`verify-containers.sh` itself does. A bind mount from `/mnt/c/...` still
works, but crosses the Windows-drive filesystem boundary (`DrvFs`): expect
materially slower metadata-heavy operations and file-watching, and treat any
Linux ownership/permission bits on files there as Windows-synthesized rather
than authoritative. `verify-containers.sh` warns, rather than fails, when
run from under `/mnt`, consistent with the rest of this WSL profile.

### SELinux

Native Fedora enforces SELinux and relies on it for the `:Z`/`:z`
bind-mount relabeling documented in the main Podman section below.
Microsoft's WSL2 kernel is not generally built with the SELinux LSM enabled,
so SELinux is typically not enforcing inside Fedora WSL even though the
Fedora userland tools (`restorecon`, `semanage`, `:Z`/`:z` themselves) are
still present — check with `getenforce` on your own instance rather than
assuming either way, since this can change with future WSL2 kernel builds.
Passing `:Z`/`:z` remains harmless either way: Podman only relabels when
SELinux is actually enabled. If SELinux is not enforcing, do not read that
as parity with native Fedora's access control — it means a bind mount that
would be denied on native Fedora may simply work here, with an ordinary
Linux file-permission check as the only remaining gate. This profile does
not attempt to change that; it is a genuine platform difference, documented
rather than hidden.

### Rootless API socket

Identical rootless-user-socket behavior to native Fedora (see "Rootless API
socket" below): `--containers-api-socket` enables `podman.socket` in your
own systemd `--user` instance only, socket-activated, never bound to TCP.
`DOCKER_HOST` is only relevant to a Docker-CLI-compatible client running
*inside this same WSL instance*; there is no bridging to a Windows-side
Docker client or named pipe, and none is planned — a Windows-side consumer
that needs a Docker-compatible endpoint is out of scope for this profile,
consistent with not installing Docker Engine or Docker Desktop inside WSL as
a parallel runtime.

### Compose and everyday commands

Unchanged from native Fedora: `podman compose`, the SELinux-label table, the
common command list, and the `depends_on` hang caveat below all apply
identically inside WSL.

### Validation status

This support was implemented and regression-tested against this
repository's own test methodology (mocked `dnf`/`podman`/`systemctl`/`ps`
bash-script tests exercising the actual install/verify scripts end to end,
see `tests/test-containers-wsl.sh`) in an environment with no real Windows
+ WSL2 + Fedora machine available.

It has since been run on a real Fedora WSL machine
(`./install.sh --platform fedora-wsl --containers`), which surfaced exactly
the kind of gap that mock-only testing cannot catch: the original
`systemd_is_running` check (PID 1 only) passed, but no `systemd --user`
session was reachable, so `podman network create`, the build step's
run-the-built-image check, and Compose all failed while everything else
passed — see the "systemd" bullet above for the failure signature and fix.
After applying that fix (checking for the reachable `systemd --user`
session bus, not just PID 1) and running `sudo loginctl enable-linger
"$(id -un)"` followed by a WSL restart, the same machine completed
`./install.sh --platform fedora-wsl --containers` end to end, including the
full pull/run/build/bind-mount/named-volume/localhost-port/
container-network/Compose smoke test that `install-containers.sh` always
runs immediately after installing. This is now confirmed working on real
Fedora WSL, not just against this repository's mocked test suite.

## Git, SSH and GitHub authentication

The simplest setup is Linux-native OpenSSH plus the Linux `gh` installed by
DNF:

```bash
ssh-keygen -t ed25519
gh auth login --hostname github.com --git-protocol ssh --web
ssh -T git@github.com
```

Private keys, GitHub tokens, identities and signing configuration stay outside
the repository. Put Git identity and optional signing settings in
`~/.config/git/local`, as on normal Fedora.

### Windows-hosted SSH agent (optional)

If a Windows-hosted SSH agent is preferred — 1Password's is the common case,
but this pattern is not 1Password-specific and this WSL profile does not
require 1Password or any other agent — use Windows OpenSSH explicitly by its
full path rather than restoring `/mnt/c/Windows/System32/OpenSSH` to `PATH`
(that would shadow, or at least sit ahead of package-manager confusion with,
the Linux `ssh` this profile installs and expects to remain authoritative).
For 1Password specifically, enable its WSL integration in the 1Password
Windows app first. Then test the explicit path directly:

```bash
/mnt/c/Windows/System32/OpenSSH/ssh.exe -T git@github.com
```

and, to confirm the agent itself has keys loaded (useful when the above
fails and you need to tell an agent problem from a known-hosts/network one):

```bash
/mnt/c/Windows/System32/OpenSSH/ssh-add.exe -l
```

Point Git at it by adding the following to `~/.config/git/local` for every
repository:

```gitconfig
[core]
    sshCommand = /mnt/c/Windows/System32/OpenSSH/ssh.exe
```

or, for one repository only, without touching machine-local config:

```bash
git config --local core.sshCommand /mnt/c/Windows/System32/OpenSSH/ssh.exe
```

This is an explicit boundary choice: without it, Git and SSH remain entirely
inside Fedora, which is the default and requires no Windows interop at all.
Either way, `ssh.exe` here is doing exactly one job — Git authentication
(clone/fetch/pull/push over SSH) — and nothing else; see "PATH and Windows
interoperability" above for why `ssh.exe` runs at all (`[interop]
enabled=true`) without Windows directories ever being added to `PATH`.

### Commit/tag signing with a Windows-hosted SSH key (optional, separate from authentication)

SSH authentication (getting `ssh.exe` to talk to GitHub) and Git commit/tag
signing (getting Git to produce a verifiable signature) are separate Git
integrations that happen to both be able to use the same SSH keypair; wiring
up one does not wire up the other. If commits should show as verified on
GitHub using a key held by a Windows-hosted 1Password, that needs its own
Git configuration pointing at 1Password's separate `op-ssh-sign-wsl.exe`
signing helper, e.g. in `~/.config/git/local`:

```gitconfig
[gpg]
    format = ssh
[gpg "ssh"]
    program = /mnt/c/.../op-ssh-sign-wsl.exe
[commit]
    gpgsign = true
[user]
    signingkey = ssh-ed25519 AAAA...
```

Do not hard-code a specific `op-ssh-sign-wsl.exe` path here: it is
per-install and per-1Password-version. Use 1Password's own generated WSL Git
signing snippet (1Password → Settings → SSH Agent → generated config for
your platform) to get the correct path, or otherwise fill it in yourself; in
either case it belongs in `~/.config/git/local`, never in this repository's
tracked Git config, for exactly the same reason `sshCommand` above does.
`user.signingkey` is the selected SSH **public** key; the matching public
key must also be registered with the Git provider (GitHub → Settings → SSH
and GPG keys, added as a **signing key**, not just an authentication key) or
commits will sign locally but still show as unverified there. In short:

| Executable | Role |
|---|---|
| `ssh.exe` | Git authentication — clone/fetch/pull/push |
| `op-ssh-sign-wsl.exe` | Git commit/tag signing |

## DNS, VPN and networking

WSL networking depends on both the Windows build and the host VPN. When an
always-on or corporate VPN breaks DNS or routing, first update WSL and compare
Windows and Fedora resolution. On supported Windows 11 versions, these
Windows-side `%UserProfile%\.wslconfig` settings are often appropriate:

```ini
[wsl2]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
```

Apply changes with `wsl --shutdown`. Corporate VPN and endpoint policy may
override them, so this repository documents the choice but does not rewrite
`resolv.conf`, routes, Windows firewall rules, proxy policy or VPN settings.

The same reasoning applies to Tailscale: `--tailscale` is intentionally not
offered under `--platform fedora-wsl` at all. See "Optional Tailscale
networking profile" > "Fedora WSL policy" for the host-vs-WSL-node
comparison and why Windows-host-only Tailscale is the recommended
architecture here.

## Validation

The normal installer verifies `command -v` ownership and starts representative
`.NET`, Node/npm/npx, Python/uv and optional OCaml commands. For disposable,
network-dependent project tests covering .NET, Angular/TypeScript, Python and
the installed OCaml profile, run:

```bash
./install.sh --platform fedora-wsl --smoke-test
```

The optional AI profile (`--ai`, `--codex`, `--firstmate`; see "AI-assisted
development toolchain" below) is portable CLI tooling with no GUI or hardware
dependency, so it is fully supported here. The early PATH policy ensures the
Linux-native, mise-managed installation always takes precedence over any
Windows executable of the same name.

---

# Parrot Security Edition CTF VM

This variant is an intentionally disposable security-lab guest. Parrot
Security Edition supplies and updates its own pentesting catalogue through its
configured APT repositories; this repository supplies only the surrounding
working environment. It neither enumerates nor reinstalls Parrot's offensive
tools.

Use the Parrot Security Edition ISO or QCOW2 image with the #13 Fedora host
profile. The reference guest keeps the same `qemu:///system` backend, qcow2
storage, UEFI/OVMF firmware, VirtIO disk/network devices, SPICE display, QEMU
guest-agent channel, and SPICE channel. A representative ISO install is:

```bash
virt-install \
  --connect qemu:///system \
  --name parrot-ctf \
  --memory 8192 \
  --vcpus 4 \
  --disk size=80,format=qcow2,bus=virtio \
  --network network=default,model=virtio \
  --graphics spice \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --channel spicevmc \
  --boot uefi \
  --cdrom ~/Downloads/Parrot-security.iso
```

## Network and integration boundary

| Concern | Reference choice |
|---|---|
| Normal network | libvirt `default` NAT; inbound access is not exposed by default |
| CTF target network | A separate isolated libvirt network with forwarding disabled; attach only the lab guests that need it |
| Host-only access | Use an isolated network shared by the host and selected guests; do not add a physical bridge |
| Bridged network | Deliberate per-lab choice only, after reviewing exposure to the physical LAN |
| Host lifecycle | APT-owned `qemu-guest-agent`, enabled through its virtio channel |
| Display/clipboard | APT-owned `spice-vdagent` over SPICE; disable clipboard sharing for untrusted labs when the client permits it |
| Shared folders | Off by default; an explicit virtiofs share is convenient but expands the path and symlink attack surface into the host |
| Credentials | No SSH agent, SSH key, cloud config, GitHub token, password-manager socket, GPG agent, or workstation secret is forwarded or mounted |

Create isolated or host-only networks in virt-manager under **Connection
Details → Virtual Networks** with forwarding set to **Isolated**. Keep the
normal NAT adapter only when the guest needs internet access; disconnect it
while working on a target network if the event does not require internet.
Bridging is never created or selected by the bootstrap.

Git and `gh` are installed because they are useful for public challenge source
and write-ups, but `gh auth login`, SSH-agent forwarding, and credential import
are never run automatically. If a private service is unavoidable, use a
separate narrowly scoped lab credential and do not bake it into a checkpoint.
AI tooling is also absent from this profile: install or invoke it only as a
deliberate per-lab decision after confirming that challenge data may leave the
guest.

## Disposable and persistent state

Keep `~/src/dotfiles` as the small persistent configuration checkout. Keep
challenge downloads, captures, malware, generated payloads, credentials, and
tool state under a separate location such as `~/labs`; treat that entire tree
as disposable. Do not put lab artifacts into this repository. Persistence is
best achieved by updating the dotfiles branch or by copying a reviewed,
non-sensitive write-up out after the lab, not by sharing the workstation home
directory.

Shut the guest down and create a checkpoint before an event, importing unknown
artifacts, installing experimental kernels/drivers, or changing network mode:

```bash
virsh --connect qemu:///system snapshot-create-as \
  parrot-ctf clean-pre-lab --description 'Clean Parrot CTF baseline'
virsh --connect qemu:///system snapshot-list parrot-ctf
```

Use virt-manager's **Snapshots** view for named checkpoints and deliberate
reverts. A revert discards later guest state, so copy out only explicitly
reviewed artifacts first. For especially hostile work, clone the clean qcow2
baseline and delete the clone afterward instead of accumulating snapshots.

## Bootstrap and validation

Inside a clean Parrot Security Edition guest:

```bash
sudo parrot-upgrade
mkdir -p ~/src
git clone <REPOSITORY_URL> ~/src/dotfiles
cd ~/src/dotfiles
./install.sh --platform parrot-ctf --dry-run
./install.sh --platform parrot-ctf
exec zsh -l
./platforms/parrot-ctf/scripts/verify.sh
./install.sh --platform parrot-ctf --non-interactive
```

The final rerun is the idempotency check. The verifier checks the Parrot and
KVM/QEMU boundaries, both virtio channels, APT ownership, guest services,
portable configuration links, Python/uv, and the recorded no-secret-sharing
state. On the host, `virsh --connect qemu:///system domifaddr parrot-ctf
--source agent` confirms that the guest agent answers.

Parrot owns Python, `venv`, pip and pipx. mise owns only `uv` in this profile;
the normal workstation's .NET, Node, Python, Mermaid and language-server
manifest is intentionally not stowed. Use `uv init`/`uv sync`, a local `.venv`,
or pipx rather than installing challenge packages into Parrot's system Python.

---

# Choices a user must make

The installer intentionally does not guess personal or security-sensitive information.

## 1. Catppuccin flavor

All four Catppuccin flavors are supported:

| Flavor | Character |
|---|---|
| Latte | Light |
| Frappé | Soft dark |
| Macchiato | Medium dark — **default** |
| Mocha | Darkest |

Switch at any time with:

```bash
theme latte
theme frappe
theme macchiato
theme mocha
```

To change the flavour while keeping the wallpaper currently selected in KDE
or Sway, pass `--preserve-wallpaper`:

```bash
theme macchiato --preserve-wallpaper
```

This preserves only the desktop wallpaper. The KDE and Sway lock-screen
wallpapers continue to follow the selected Catppuccin flavour.

The selection is stored locally in:

```text
~/.config/dotfiles/theme
```

Changing flavor does **not** modify tracked dotfiles.

## 2. Git identity

Shared Git behavior is tracked, but identities are local.

Configure:

```text
~/.config/git/local
```

Example:

```gitconfig
[user]
    name = Your Name
    email = you@example.com
```

A separate DR/work identity can be placed in:

```text
~/.config/git/drdk
```

Example:

```gitconfig
[user]
    name = Your Work Name
    email = you@work.example
```

The tracked Git configuration conditionally applies the DR profile for remotes matching the `drdk` GitHub organization.

## 3. SSH authentication

SSH authentication is intentionally not automated.

Supported approaches include:

- 1Password SSH Agent
- normal OpenSSH keys
- another existing SSH agent

Verify authentication with:

```bash
ssh -T git@github.com
```

## 4. GitHub CLI authentication

After installation:

```bash
gh auth login \
  --hostname github.com \
  --git-protocol ssh \
  --web \
  --skip-ssh-key
```

Multiple GitHub CLI accounts can be managed independently with:

```bash
gh auth switch
```

## 5. Commit signing

SSH commit signing is optional and user-specific.

For 1Password:

1. Open the SSH key in 1Password.
2. Choose **Configure Commit Signing**.
3. Copy the Git configuration snippet.
4. Put the signing configuration in `~/.config/git/local`.
5. Register the public key on GitHub as a **Signing key**.

Do not commit signing keys or user-specific signing configuration to this repository.

## 6. ASUS laptop hardware

Hardware setup is deliberately separate from the default workstation install.
It currently supports these ROG Zephyrus G14 profiles:

| Profile | Laptop | Graphics stack |
|---|---|---|
| `ga402xz` | 2023 GA402XZ | Fedora AMD iGPU plus RPM Fusion NVIDIA akmod |
| `ga402rk` | 2022 GA402RK, including GA402RK-L81152 | Fedora AMD firmware, kernel `amdgpu`, and Mesa |

Run the component directly when the workstation configuration is already
installed:

```bash
./scripts/install-asus-hardware.sh \
  --model ga402xz \
  --secure-boot \
  --charge-limit 80

./scripts/install-asus-hardware.sh \
  --model ga402rk \
  --secure-boot
```

`--secure-boot` requires Secure Boot to be enabled, but never changes UEFI
firmware settings itself. On the NVIDIA model, the installer also prepares the
akmods signing certificate and can initiate interactive MOK enrollment. The
all-AMD GA402RK needs no MOK; the option simply records and verifies that Secure
Boot remains enabled. If the flag is used while Secure Boot is disabled, the
installer fails its read-only preflight before enabling repositories, installing
packages, or changing services.

The preflight can also be run independently:

```bash
./scripts/install-asus-hardware.sh \
  --model ga402rk \
  --secure-boot \
  --preflight
```

Before running either hardware profile on a fresh Fedora installation, fully
update the operating system and firmware, then reboot:

```bash
sudo dnf upgrade --refresh
sudo fwupdmgr refresh
sudo fwupdmgr get-updates
sudo fwupdmgr update
sudo reboot
```

The hardware installer:

- requires Fedora and a kernel of at least 7.1
- enables Terra and installs `asusctl` plus ROG Control Center
- starts `asusd.service` and enables `asus-shutdown.service`
- gives `asusd` sole ownership of power-profile and CPU EPP changes by
  masking installed PPD/Tuned services
- leaves GPU/MUX mode unchanged
- changes the battery charge limit only when requested
- never flashes firmware or reboots the machine

Do not add `supergfxctl`; it has been removed from current `asusctl`. Cardwire
is still experimental and is not part of this setup. Use ROG Control Center or
`asusctl armoury list` to inspect the firmware GPU controls. Changing the
firmware dGPU setting requires a reboot and may affect which external display
ports remain available.

The conflicting power-profile services are masked, rather than merely
disabled, because KDE PowerDevil can reactivate `power-profiles-daemon` through
D-Bus after a reboot. To return profile ownership to PPD or Tuned, first disable
profile management in `asusd`, then explicitly unmask the chosen service.

If the GA402XZ akmods certificate is not yet enrolled, the installer offers to
queue it for MOK enrollment and then stops before installing or rebuilding the
NVIDIA module. Reboot into MOK Manager, choose **Enroll MOK**, enter the
temporary password, and continue booting. Rerun the same hardware installation
command after reboot; the NVIDIA work begins only after the privileged MOK
check confirms that the certificate is enrolled.

Then run:

```bash
./scripts/verify-asus-hardware.sh
```

## 7. SFTP client

Command-line SFTP is part of the base workstation install; no installer flag
is required. It comes from Fedora's own `openssh-clients` package — the same
package that provides `ssh` and `scp` — so there is never a second SSH
implementation to manage.

```bash
sftp user@host
```

Common interactive commands:

```text
ls
cd
lcd
pwd
lpwd
get
put
mget
mput
mkdir
rm
exit
```

Non-interactive transfers use `scp`:

```bash
scp file.txt user@host:/remote/path/
scp -r local-dir/ user@host:/remote/path/
scp user@host:/remote/path/file.txt .
```

Both tools use standard SSH authentication: `~/.ssh/config`, SSH keys,
ssh-agent (including a 1Password-backed agent), and password authentication
when a server requires it. No credentials, keys, or host-specific bookmarks
are tracked by this repository; that state stays machine-local.

Verify the baseline with:

```bash
command -v sftp
command -v scp
ssh -V
```

**KDE**: Dolphin/KIO already provides a native SFTP workflow, reused instead
of installing a dedicated application. `platforms/fedora/scripts/install-kde-theme.sh`
explicitly ensures Fedora's `kio-extras` package — which supplies Dolphin's
`sftp://` support — is installed, rather than assuming it. Open a location
directly:

```text
sftp://user@host/path
```

either by typing it into Dolphin's location bar or from the Network places
sidebar entry. It authenticates through the same SSH key/agent as the CLI,
and supports normal drag/drop and recursive folder transfers. This is reused
as-is; no dedicated SFTP application is installed for KDE.

**Sway**: the optional `--sway` session (see "Optional Sway session") runs on
top of the same Fedora KDE Plasma base as the rest of this profile, so Dolphin
and the `kio-extras` sftp:// support ensured above are available there too —
launch Dolphin from Fuzzel exactly as under Plasma. No dedicated Sway-specific
GUI SFTP client is added, since Dolphin already solves the same usability gap
in both sessions.

A standalone GUI client such as FileZilla was evaluated and rejected: Dolphin
already gives both KDE and Sway a working native SFTP path with SSH key/agent
support, drag/drop, and recursive transfers, so a second GUI application would
duplicate functionality rather than close a real gap.

## 8. AI agent authentication

Only relevant if the optional AI profile (`--ai`) is selected; see
"AI-assisted development toolchain" below for the full picture. Nothing here
is stored in this repository, and none of it is requested or configured by
the installer:

- Claude Code: run `claude`, follow the browser login prompt (or set
  `ANTHROPIC_API_KEY`).
- Codex (if installed): run `codex`, choose "Sign in with ChatGPT" (or
  configure an OpenAI API key).
- FirstMate (if installed): uses your own `gh auth login`.
- GNHF (if installed): no separate auth; shells out to your already-signed-in
  `claude` (or configured `--agent`). Read its README before your first
  unattended run.
- backpass (if installed): no separate auth; every model call goes through
  `acpx` to a harness you have already authenticated.

---

# Installation architecture

The repository has platform-specific ownership layers around one portable core:

| Layer | Owns | Must not own |
|---|---|---|
| Portable common | Shared Stow packages, user-local Git/theme state, mise tools, opam switch/tool setup, and the tmux theme | Native package-manager installation, services, hardware, desktop integration, or OS-specific paths |
| `platforms/fedora` | DNF/Terra packages, including the opam binary and OCaml build prerequisites; KDE and Sway integration; system services; SELinux/system paths; Secure Boot; and ASUS hardware | Copies of shared Zsh/Git/Neovim/tmux/mise configuration or OCaml packages inside opam switches |
| `platforms/fedora-wsl` | WSL detection, CLI prerequisites, early Windows PATH isolation, explicit clipboard/browser interop and WSL verification | Fedora desktop, Ghostty, hardware, GPU, VM host/guest, invasive host networking changes, credentials or copies of portable configuration |
| `platforms/macos` | Native `/opt/homebrew` packages, AeroSpace, Mac shell paths, deliberate defaults, Podman machine integration, and arm64/security verification | Copies of shared configuration, Rosetta, Intel Homebrew, weakened SIP/Gatekeeper, identities, credentials, or Fedora service assumptions |
| `platforms/parrot-ctf` | Parrot/APT prerequisites, KVM/SPICE guest agents, Debian command shims, a narrow uv-only mise manifest, and lab-boundary verification | Fedora/Terra/KDE/ASUS provisioning, host virtualization, credentials, shared folders, or a duplicate Parrot security-tool catalogue |

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
    ├── common/install-mise.sh                         uv only
    ├── common/install-tmux-theme.sh
    └── platforms/parrot-ctf/scripts/verify.sh
```

## Optional VM-host profile

The VM-host profile uses Fedora's native virtualization stack:

| Concern | Convention |
|---|---|
| Backend | KVM/QEMU managed by libvirt |
| libvirt connection | `qemu:///system` |
| Primary graphical client | `virt-manager` |
| CLI and automation | `virt-install` and `virsh` |
| Guest console | `virt-viewer` with SPICE where supported |
| Guest firmware | UEFI/OVMF; `swtpm` is available for guest TPM support |
| Guest devices | VirtIO disk and network devices |
| Accelerated display | Virtio video with 3D acceleration and local SPICE OpenGL |
| Guest disks | `qcow2` in the libvirt `default` storage pool |
| Storage path | `/var/lib/libvirt/images` (managed by libvirt) |
| Default network | libvirt `default` NAT network |
| Guest agent | Install and enable `qemu-guest-agent` inside each guest |

The profile activates the existing libvirt system service/socket units and the
default NAT network and storage pool. It does not create a bridge, expose a
new externally reachable service, or change host Secure Boot, SELinux, or
firewalld. Bridged networking is intentionally outside this profile and must
be designed as a separate, explicit option if it is needed later.

Normal users use Fedora's upstream libvirt/polkit policy and, where Fedora
provides it, the standard `libvirt` group. The installer never makes the
libvirt socket world-writable and never grants broad administrator permissions.
After a group change, log out and back in before using `qemu:///system`.

Validation checks `virt-host-validate qemu`, KVM device availability, access to
`qemu:///system`, the active/autostart NAT network, and the active/autostart
storage pool. The optional `--smoke-test` renders a representative UEFI guest
definition with qcow2, VirtIO, the default network, and SPICE without creating
or booting a guest.

`virt-host-validate qemu` may report two advisory warnings on modern Fedora
hosts:

- A missing `devices` cgroup controller affects optional resource-control
  features; it does not prevent normal QEMU guests from running. Libvirt's QEMU
  driver does not require every resource controller to be mounted.
- Missing SEV/SEV-ES/SEV-SNP/TDX support means confidential encrypted guests are
  unavailable on the host. It is unrelated to Secure Boot and does not affect
  ordinary KVM guests.

These warnings do not disable or weaken Secure Boot, SELinux, or firewalld, and
the verifier reports them as advisory when the required KVM/libvirt checks pass.
See the [libvirt cgroups documentation](https://libvirt.org/cgroups.html) and
[domain security documentation](https://libvirt.org/formatdomain.html) for
the optional features involved.

To boot a real guest, supply an installer ISO explicitly, for example:

```bash
virt-install \
  --connect qemu:///system \
  --name fedora-test \
  --memory 4096 \
  --vcpus 4 \
  --disk size=40,format=qcow2,bus=virtio \
  --network network=default,model=virtio \
  --graphics spice \
  --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
  --channel spicevmc \
  --boot uefi \
  --cdrom ~/Downloads/Fedora.iso
```

For the tested Fedora KDE development guest, shut the VM down and apply these
settings in virt-manager's hardware details before enabling acceleration:

| Setting | Value |
|---|---|
| Memory | 8192 MiB for both current and maximum allocation |
| CPUs | 8 virtual CPUs with host-passthrough |
| Video | Virtio with **3D acceleration** enabled |
| Display | SPICE with **OpenGL** enabled |
| SPICE listen type | **None**; native SPICE OpenGL is local-only and cannot use the normal TCP listener |
| Render node | The host's Mesa-backed AMD iGPU render node, preferably its stable `/dev/dri/by-path/...-render` path |
| Console resizing | **View → Scale Display → Resize guest with window**; this is disabled by default |

Render-node numbering is machine-specific. Identify the stable device paths
and their PCI devices on the host rather than assuming `renderD128`:

```bash
for node in /dev/dri/renderD*; do
  device_path="$(readlink -f "/sys/class/drm/${node##*/}/device")"
  pci_address="${device_path##*/}"
  printf '\n%s -> %s\n' "$node" "$pci_address"
  lspci -nnk -s "$pci_address"
done

ls -l /dev/dri/by-path/*-render
```

The resulting graphics and video XML should have this shape, with the actual
AMD render-node path substituted:

```xml
<graphics type='spice'>
  <listen type='none'/>
  <gl enable='yes' rendernode='/dev/dri/by-path/AMD-PCI-PATH-render'/>
</graphics>
<video>
  <model type='virtio' heads='1' primary='yes'>
    <acceleration accel3d='yes'/>
  </model>
</video>
```

After booting the guest, verify the renderer:

```bash
glxinfo -B |
  grep -E 'direct rendering|OpenGL vendor|OpenGL renderer|OpenGL version'
```

The OpenGL renderer should contain `virgl`; `llvmpipe` means the desktop is
still rendering on the guest CPU. `eglInitialize failed` or `render node init
failed` points to the selected host render node or its host driver. If QEMU
reports that the display backend lacks OpenGL support, confirm that SPICE uses
`<listen type='none'/>` rather than `<listen type='address'/>`. This virtual
acceleration path does not require PCI-passing the laptop's NVIDIA dGPU.

The saved local state file is:

```text
~/.config/dotfiles/vm-host.conf
```

Removing the profile is deliberately conservative: stop and remove guests
explicitly with `virsh`, preserve or delete images intentionally, then remove
the packages with DNF. The installer does not delete guest disks, networks,
or storage pools on rerun or rollback. Issues #17 and #19 should reuse this
libvirt system backend and these storage/network conventions rather than add a
second provisioning path.

## Optional VM-guest profile

The normal Fedora bootstrap is also the guest bootstrap. Validation of its
composition found no reason to copy the Fedora installer or any Stow package:

| Area | Guest result |
|---|---|
| Portable dotfiles and developer tools | Reused unchanged |
| Fedora base and Terra packages | Reused unchanged |
| KDE theming | Reused unchanged |
| ASUS/NVIDIA laptop provisioning | Already opt-in; rejected when `--vm-guest` is selected |
| Power management | No guest override; laptop-specific masking runs only in the hardware profile |
| Networking | Left to the guest and hypervisor; the #13 default network supplies normal NAT/DHCP |
| Clipboard and pointer integration | Requires `spice-vdagent` and the SPICE virtio channel; host-to-guest works in Plasma Wayland, while `xclip` provides an explicit one-shot guest-to-host workaround for the packaged agent's X11 clipboard limitation |
| Display and resolution | SPICE supplies modes and pointer integration; enable virt-manager's **Resize guest with window** setting on the host for automatic resizing |
| Host lifecycle integration | Requires `qemu-guest-agent` and its virtio channel |
| Shared folders | Kept manual because the host path and security boundary are machine-specific |

Run the profile only inside the guest:

```bash
./scripts/install-vm-guest.sh
./scripts/verify-vm-guest.sh
```

It uses `systemd-detect-virt --vm` as an explicit preflight and currently
accepts only `kvm` and `qemu`. Other hypervisors are detected and rejected
before DNF runs, rather than receiving inappropriate QEMU packages. This check
exists only in the selected guest component, so it cannot change the normal
physical Fedora path.

The reference VM must expose these two virtio-serial channels:

```text
org.qemu.guest_agent.0
com.redhat.spice.0
```

The host example above and the VM-host `--smoke-test` include both. In
virt-manager they can also be inspected or added in the guest hardware details.
Fedora starts the QEMU system agent and activates the static SPICE socket from
its virtio-port udev rule; Plasma starts the packaged SPICE user agent with its
graphical session. In the tested Plasma Wayland guest, host-to-guest clipboard
sharing works, while guest-to-host succeeds only when text is placed directly
on the X11 clipboard. The packaged `spice-vdagent` therefore does not provide
complete bidirectional Wayland clipboard integration in this environment. The
guest profile installs `xclip` so text already copied by a Wayland application
can be exported explicitly to SPICE's X11 clipboard path:

```bash
wl-paste --no-newline | xclip -selection clipboard -in
```

Run that command once after copying text in the guest, then paste it on the
host. It is intentionally a manual, text-only workaround rather than a
background clipboard synchronizer.

An attempted `wl-paste --watch` to `xclip` bridge was rejected because feedback
between KWin's Wayland and X11 clipboards immediately repeated clipboard
ownership changes and froze the desktop. The installer removes that legacy
user unit if an earlier test revision installed it; it does not replace the
upstream clipboard implementation with polling or another fragile bridge.

The verifier checks the packages, both channels, both system units, rejects an
active legacy clipboard bridge, and checks a default network route. If Plasma
is not running, the user-session check can be repeated after login. Verify both
clipboard directions explicitly; in Ghostty use `Ctrl+Shift+C`, because
`Ctrl+C` does not copy terminal text.

On Plasma Wayland, `spice-vdagent` may log a failed call to
`org.gnome.Mutter.DisplayConfig` because that GNOME API is not provided by KWin.
This is harmless in the tested KDE guest and does not indicate a missing SPICE
channel. Automatic resizing works after selecting **View → Scale Display →
Resize guest with window** in virt-manager; this host-side option is not enabled
by default. The bootstrap deliberately does not hard-code a resolution or scale
because both follow the host display and console window.

The profile also does not alter NetworkManager, sleep policy, battery settings,
or shared folders. For an optional virtiofs share, choose the host path and guest
mount point explicitly in virt-manager; `/mnt/shared` is a reasonable guest
convention, but the bootstrap does not create or mount it.

DNF and systemd operations are safe to repeat, and
`~/.config/dotfiles/vm-guest.conf` is rewritten atomically with stable content.
The Fedora packages are deliberately guest-owned: `qemu-guest-agent` is no
longer installed by the VM-host profile.

## Optional Fedora security-hardening profile

This is a conservative, explicit workstation-hardening profile, not the Parrot
Security Edition CTF guest under `platforms/parrot-ctf`. The Parrot guest is a
disposable, offensive-security lab environment (see "Parrot Security Edition
CTF VM" above); this profile does the opposite: it makes the everyday Fedora
host a little more resistant to local attacks while staying a normal
day-to-day development machine. The two are intentionally unrelated code
paths and are never installed together by the same flag.

It never disables SELinux or firewalld, never installs or enables an SSH
server, never changes firewalld zone services, never reboots, and never
touches UEFI/Secure Boot settings. Every change it makes is a small, named,
dotfiles-owned drop-in file, so any single change can be rolled back by
deleting one file. It is opt-in and does not change the default install:

```bash
./install.sh --hardening
```

or, once the base workstation is already installed:

```bash
./scripts/install-hardening.sh
./scripts/install-hardening.sh --dry-run   # show the plan first
./scripts/verify-hardening.sh              # re-run verification any time
```

### Fedora's baseline (verified, not changed)

Fedora Workstation already provides real protection out of the box. This
profile verifies the following instead of reconfiguring it — `verify.sh`
checks the first two unconditionally, on every run, whether or not
`--hardening` was ever used:

| Protection | Fedora default | This profile |
|---|---|---|
| SELinux | Enforcing, targeted policy | Verified every `verify.sh` run; see below if it has drifted |
| firewalld | Active, default-deny inbound except the `FedoraWorkstation` zone's mDNS/dhcpv6-client/samba-client | Verified every `verify.sh` run; zone services are reported, not changed |
| ASLR, stack protector, `fs.protected_*`, TCP SYN cookies | Already on by default in Fedora's kernel/glibc/toolchain defaults | Not touched; there is nothing to add |
| Package integrity | DNF verifies GPG signatures on all configured repositories | Not touched |
| SSH server | Not installed on Fedora Workstation | Not installed by this profile either; see below |
| Automatic updates | Off; you update manually via `dnf`/GNOME Software/KDE Discover | Optionally switched to notify-only, never silent/automatic (see below) |
| Secure Boot | Machine-dependent; use the ASUS hardware profile's `--secure-boot` flag on supported laptops | Reported by `verify.sh`/`verify-hardening.sh`, never modified |

### What the profile changes

| Change | Rationale | Verify | Rollback | Compatibility |
|---|---|---|---|---|
| SELinux permissive → enforcing (only if currently permissive; a disabled system needs a manual relabel + reboot, so the installer warns instead of forcing one) | Keeps the acceptance criterion "SELinux remains enforcing" true even if it was manually loosened | `getenforce` | `sudo setenforce 0` and revert `SELINUX=` in `/etc/selinux/config` | None for a workstation running its default targeted policy |
| `kernel.yama.ptrace_scope=1` (`/etc/sysctl.d/90-dotfiles-hardening.conf`) | Fedora ships `0`; `1` still allows a debugger to attach to its own child processes (gdb/lldb, VS Code, Neovim DAP, `dotnet` debuggers), only blocking attaching to an unrelated running process without root | `sysctl kernel.yama.ptrace_scope` | Delete the sysctl file, `sudo sysctl --system` | Attaching a debugger to an already-running, unrelated process needs `sudo`; launching and debugging your own process is unaffected |
| `kernel.kptr_restrict=2` | Fedora ships `0`; hides kernel pointers from `/proc` for non-root users, closing an info leak used to defeat KASLR | `sysctl kernel.kptr_restrict` | Delete the sysctl file, `sudo sysctl --system` | None for application-level development; only affects reading `/proc/kallsyms`-style kernel debugging as non-root |
| `kernel.dmesg_restrict=1` | Fedora ships `0`; requires `CAP_SYSLOG` to read the kernel ring buffer | `sysctl kernel.dmesg_restrict` | Delete the sysctl file, `sudo sysctl --system` | `dmesg` needs `sudo dmesg` afterward |
| `pam_faillock`: lock an account for 15 minutes after 5 failed password attempts (`authselect enable-feature with-faillock`, `/etc/security/faillock.conf.d/90-dotfiles-hardening.conf`) | Fedora ships no lockout at all; mitigates local password guessing against your login/sudo password | `authselect current` (look for `with-faillock`); `sudo faillock --user "$USER"` | `sudo authselect disable-feature with-faillock`; delete the faillock drop-in; `sudo faillock --user "$USER" --reset` clears an active lockout | Mistyping your password 5 times in a row locks the account for 15 minutes |
| sudo audit logfile (`Defaults logfile="/var/log/sudo.log"` in `/etc/sudoers.d/90-dotfiles-hardening`, validated with `visudo -cf` before install) | Fedora's default sudo keeps no dedicated audit trail beyond journald | `sudo test -f /etc/sudoers.d/90-dotfiles-hardening`; `sudo tail /var/log/sudo.log` | Delete the file | None; pure logging addition |
| `auditd` with a short watch list (`/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/sudoers`, `/etc/sudoers.d/`) | Fedora Workstation does not install `auditd`; watching identity/sudo files gives a tamper-evident trail for a small, fixed set of security-relevant files rather than full syscall auditing | `systemctl is-active auditd`; `sudo auditctl -l` | `sudo systemctl disable --now auditd`; delete the rules file | A few file-write-triggered audit events; negligible CPU/disk cost next to full syscall auditing (which this profile deliberately does not enable) |
| Conservative sshd posture — **only if `sshd` is already active or enabled**: `PermitRootLogin no`, `MaxAuthTries 3`, `LoginGraceTime 20` (`/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf`, validated with `sudo sshd -t` before reload) | Fedora Workstation does not install/enable an SSH server, so this profile never installs one just to harden it (per the design constraint); if you've enabled `sshd` yourself, these are small, config-scoped hardenings, not a rewrite of `sshd_config` | `sudo sshd -T` (check `permitrootlogin` and `maxauthtries`) | Delete the drop-in, `sudo systemctl reload sshd` | Only relevant if you already run `sshd`; password-only root login and unlimited auth retries stop working, key-based non-root login is unaffected |
| `dnf5-automatic.timer` (Fedora 41+ replaced dnf4's separate `dnf-automatic-notifyonly`/`-install`/`-download` timers with this single timer, whose behavior comes from `/etc/dnf/automatic.conf`; the packaged default `apply_updates = no`, `download_updates = yes` already means "download and report, never auto-install") | A developer workstation should not silently install or reboot on a schedule, but knowing updates are available is useful | `systemctl is-enabled dnf5-automatic.timer` | `sudo systemctl disable --now dnf5-automatic.timer` | None; you still update manually, on your own schedule. If the timer is already enabled (any pre-existing policy, including a custom `apply_updates=yes` override), it's left alone rather than reconfigured |

### Report-only checks (never change anything)

`verify-hardening.sh` also reports, but never modifies:

- **Mount options** for `/tmp`, `/dev/shm`, `/boot`, `/home` (`findmnt`). Fedora's
  systemd-managed defaults here are already reasonable for a dev workstation;
  `noexec` on `/tmp` in particular is a common source of broken installers
  (npm/pip/dotnet postinstall scripts) and is deliberately not added.
- **Service watch-list**: whether a short, named list of services with no
  clear single-user dev-laptop use case (`avahi-daemon`, `cups-browsed`,
  `rpcbind`, `nfs-server`, `smb`, `vsftpd`, `telnet`) is enabled, plus a raw
  `ss -tuln` listening-socket dump. Nothing is auto-disabled: proving a
  service is unneeded requires knowing the actual machine (does it use
  network printing? AirPlay-style discovery? Samba shares?), which a repo
  script cannot safely assume. Review the list and disable by hand if a
  service doesn't apply to you.
- **Credential/secrets permissions**: `~/.ssh/id_*`, `~/.aws/credentials`,
  `~/.config/gh/hosts.yml`, and GPG private keys under
  `~/.gnupg/private-keys-v1.d/`, flagged if group/world-readable. OpenSSH
  already refuses to use an over-permissive private key itself; this just
  surfaces the same class of problem for tools that don't.
- **Secure Boot state**, via the same `mokutil`/efivars probe the ASUS
  hardware profile uses. Informational only; see that profile's
  `--secure-boot` flag to make Secure Boot itself a hard requirement on
  supported laptop hardware.

### Rejected ideas

Considered and deliberately left out, to keep this a daily-driver workstation
profile rather than a lab/appliance policy:

| Idea | Why it was rejected |
|---|---|
| `noexec` on `/tmp` | Breaks common installers/build tooling (npm/pip/dotnet postinstall scripts, some test runners) that execute from `/tmp`; Fedora already sets `nosuid,nodev` there |
| USBGuard (default-deny new USB devices) | Real value against physical/"evil maid" attacks, but causes constant friction plugging in USB drives, dongles, and peripherals on a laptop used in different locations; out of this profile's threat model |
| Wi-Fi MAC address randomization (`wifi.cloned-mac-address=random`) | Can silently break networks that use MAC-based access control or static DHCP reservations, including managed corporate Wi-Fi; a workstation convenience/privacy trade the user should opt into per-network, not globally |
| `net.ipv4.conf.all.rp_filter=1` (strict reverse-path filtering) | Fedora's existing NetworkManager-set default is already reasonable; forcing strict mode globally is known to interfere with VPN split-tunnel and subnet-router setups (for example Tailscale exit nodes/subnet routes), which this profile must not break |
| `kernel.unprivileged_bpf_disabled=1` | Closes a real local-privesc surface, but also blocks unprivileged `bpftrace`/`perf`-style tracing tools some debugging workflows use; the marginal single-user-workstation benefit didn't clear the bar against breaking a real (if less common) dev workflow |
| Disabling `systemd-coredump` / capping core dumps | Crash dumps can contain sensitive memory (decrypted secrets, private keys), but this repo explicitly supports native/OCaml debugging workflows that rely on post-mortem crash inspection via `coredumpctl`; kept at Fedora's default, documented as a trade-off instead |
| Rewriting `firewalld`'s default zone services (dropping mDNS/samba-client) | Would break local network discovery, printing, and KDE integration on a workstation for a negligible security gain on a single-user laptop; reported, not changed |
| A single opaque "harden everything" script | Every change here is its own small, named, independently reversible drop-in instead, per the issue's own guidance to prefer small explicit changes |
## Optional desktop-tools profile

`--desktop-tools` adds a small, deliberate set of day-to-day desktop
applications for a general-purpose Fedora KDE workstation. It is not part of
the default `./install.sh` path, appears in `--dry-run`, and can be run and
rerun on its own:

```bash
./scripts/install-desktop-tools.sh
./scripts/install-desktop-tools.sh --dry-run
./scripts/verify-desktop-tools.sh
```

The Fedora KDE baseline was inspected first so the profile reuses what is
already an adequate default instead of installing a duplicate:

| Category | Reused from the KDE baseline | Added by this profile | Why |
|---|---|---|---|
| Images | Gwenview (fast viewer, EXIF-aware rotation) | GIMP | The baseline has no general-purpose raster editor |
| PDF | Okular (viewer, annotation) | pdfarranger | Okular views and annotates but does not merge, split, reorder, or extract pages |
| Archives | Ark (integrated with Dolphin) | — | Already covers common formats graphically |
| Media | — | mpv | The baseline has no reliable general-purpose audio/video player for files it does not already handle |
| Scanning | — | Skanpage | The baseline has no scanning/document-capture front end |

The installer checks with `rpm -q` before touching Gwenview, Okular, or Ark,
and only installs one if it is genuinely missing; a normal Fedora KDE
workstation triggers no baseline installs at all.

Rejected alternatives:

- **Krita** and **Pinta** for the image editor: Krita is a digital-painting
  application, heavier than needed for crop/resize/retouch tasks; Pinta is
  lighter but has seen little maintenance. GIMP remains the maintained,
  general-purpose choice.
- **Xournal++** for PDF annotation: Okular already annotates PDFs well, so
  adding a second annotation tool would duplicate a responsibility the
  baseline already covers. pdfarranger is deliberately a page-manipulation
  tool, not another viewer or annotator.
- **LibreOffice Draw** for PDF manipulation: it is a full office suite; the
  issue this profile implements explicitly asks not to conflate a PDF
  workflow with an office suite unless one is genuinely needed.
- **Haruna** or **Dragon Player** for media: both are Plasma-integrated but
  pull in additional Plasma/QML runtime dependencies for a single-purpose
  player; mpv is a smaller, Wayland-native binary with broader format support
  through ffmpeg and works identically under Sway.

### Package ownership

All additions are Fedora/DNF-owned, consistent with the rest of the
workstation:

```text
gimp
pdfarranger
skanpage
xdg-utils
```

`mpv` also comes from DNF, but requires the RPM Fusion repositories (enabled
automatically, the same way `install-asus-hardware.sh` already can) because
Fedora's own repositories ship only `ffmpeg-free`, a patent-conservative
build that omits codecs several common media files use. RPM Fusion's `mpv`
package pulls in its full `ffmpeg` as an ordinary DNF dependency instead.
No Flatpak is used anywhere in this profile: every selected application is
actively maintained, Wayland/KDE-friendly, and already well packaged for
Fedora, so Flatpak's extra sandboxing and duplicated runtime would add
overhead without a concrete advantage. See the [Fedora multimedia
guidance](https://rpmfusion.org/Configuration) for the underlying RPM Fusion
setup this profile automates.

### File associations

The installer sets default applications with `xdg-mime` for the mimetypes
each new or reused tool owns (common image formats to Gwenview, PDF to
Okular, common archive formats to Ark, common audio/video formats to mpv).
By default each mimetype is only claimed if it currently has no default or
is already set to the profile's choice; an existing, different default you
or another application configured is left untouched and logged, on both the
first run and every rerun. GIMP, pdfarranger, and Skanpage do not claim any
file associations: they are opened explicitly (from Dolphin's "Open With"
menu, `gimp`/`pdfarranger`, or the applications menu), not made the default
handler for a mimetype another tool already owns.

Pass `--force-defaults` to `install-desktop-tools.sh` (or
`--desktop-tools-force-defaults` to the top-level `./install.sh`) to
override an existing, different default instead of leaving it alone. This
replaces any prior choice — yours or another program's — for the mimetypes
listed above with the profile's own; it does not touch any other mimetype.
Use it when you want this profile's choices to win outright, for example on
a fresh machine coming from a different desktop's defaults. The chosen mode
is recorded as `force_defaults` in the profile's state file so a later
unqualified rerun still shows what the last run actually did.

The saved local state file is:

```text
~/.config/dotfiles/desktop-tools.conf
```

## Optional Podman container development profile

`--containers` (issue #89) adds a complete, validated rootless container
development workflow. It is not part of the default `./install.sh` path,
appears in `--dry-run`, and can be run and rerun on its own:

```bash
./scripts/install-containers.sh
./scripts/install-containers.sh --dry-run
./scripts/verify-containers.sh
```

Rootless Podman is treated as the normal, supported mode; nothing here runs
containers as root, and no setuid/daemon-as-root shortcut is used.

| Concern | Convention |
|---|---|
| Runtime | Podman, rootless by default |
| OCI runtime | `crun`, a podman dependency |
| Rootless networking | `netavark`/`aardvark-dns` plus `pasta` (or `slirp4netns`), podman dependencies |
| Compose | `podman-compose`, picked up automatically by `podman compose` |
| Buildah / Skopeo | Not installed (see below) |
| Docker Engine / `docker` alias | Not installed |
| API socket | Rootless user socket, opt-in via `--api-socket`, never over TCP |

This profile touches nothing that #13's KVM/QEMU/libvirt VM-host profile,
#14's optional hardening profile, LazyVim, or the .NET/JS-TS-Angular/Python/
OCaml toolchains rely on: it does not change SELinux, firewalld, sudoers,
sysctl, libvirt, or any mise/opam-managed runtime, so it can be enabled
alongside any of them in any order. A future optional AI-tooling profile
(#16) is expected to compose the same way.

### Package ownership

```text
podman
podman-compose
```

Both come from Fedora/DNF, consistent with the rest of the workstation.
Podman's own RPM dependencies pull in whichever OCI runtime and rootless
networking stack the current Fedora release ships — `crun`, `netavark`,
`aardvark-dns`, and `pasta` (from the `passt` package) or `slirp4netns` — so
this profile does not pin those package names itself. Pinning them would
drift from whatever Fedora's own podman package actually requires release to
release; instead, `verify-containers.sh` checks the resulting rootless
network backend and OCI runtime at runtime, so the check tracks Fedora
rather than a hard-coded list.

**Buildah and Skopeo are deliberately not installed.** `podman build` already
uses Buildah's library internally, so a separate Buildah CLI would duplicate
that path without adding a capability this profile's workflows need. Skopeo's
distinct value is inspecting or copying images between registries without
a local container store; none of this profile's pull/run/build/Compose
workflows need that, so it is left out until a concrete use case asks for it.

**No Docker Engine, no `docker` alias.** This profile never installs Docker
Engine or Docker Desktop as a second runtime, and it never aliases `docker`
to `podman` or installs another compatibility shim. If a tool insists on the
literal `docker` command, install the small `podman-docker` RPM yourself and
review what it changes; the profile does not do this for you.

### Rootless setup: subuid/subgid

Rootless Podman maps container UIDs/GIDs into a range of extra UIDs/GIDs
owned by your normal user (`/etc/subuid` and `/etc/subgid`). Fedora's
`useradd` already assigns a range to every new local user, so on most
workstations this profile finds an existing entry and changes nothing.
Only when your user has no entry does the installer allocate one:

- It scans `/etc/subuid`/`/etc/subgid` for the highest range already in use
  and allocates the next free 65536-wide block at or above Fedora's own
  `100000` floor, so it never collides with another user's range.
- It applies the allocation with `usermod --add-subuids`/`--add-subgids`,
  then runs `podman system migrate` once so any already-initialized
  rootless storage adopts the new mapping without a logout.
- A user who already owns both ranges is left untouched on every rerun.

### Common Podman commands

```bash
podman pull IMAGE                       # fetch an image
podman run --rm -it IMAGE sh            # run and drop into a shell
podman build -t NAME .                  # build from a Containerfile
podman ps                               # list running containers
podman images                           # list local images
podman volume ls                        # list named volumes
podman logs -f CONTAINER                # follow a container's logs
podman exec -it CONTAINER sh            # shell into a running container
podman system prune                     # remove unused containers/images/networks
```

These are the same commands Docker users already know; the differences that
matter day to day are covered below. See issue #72 for the project's
consolidated per-profile command cheat sheet, which should list only the
high-value entries above rather than the full Podman CLI surface.

### Compose

`podman compose` is Podman's own front end for Compose files; it shells out
to `podman-compose`, which DNF installs and which `podman compose`
auto-detects on `PATH`. No custom orchestration wrapper is added. A minimal
multi-service project:

```yaml
# compose.yaml
services:
  web:
    image: docker.io/library/busybox:stable
    command: httpd -f -p 8080 -h /srv
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - site-data:/srv
volumes:
  site-data:
```

```bash
podman compose up -d
curl http://127.0.0.1:8080/
podman compose down -v
```

### SELinux volume labels

SELinux stays enabled and enforcing; this profile never disables or weakens
it to make a bind mount work. On an SELinux-enforcing host, a bind-mounted
host directory is denied by default because the host path's SELinux context
does not match what the container is allowed to read. Podman's `:Z`/`:z`
mount-flag suffixes ask Podman to relabel the path instead of turning
enforcement off:

| Suffix | Effect | Use when |
|---|---|---|
| `:Z` | Relabels the path for **exclusive** use by this one container | The default: only one container needs the path at a time |
| `:z` | Relabels the path for **shared** use by multiple containers | Several containers (or a Compose project's services) read/write the same host path concurrently |
| (none) | No relabeling; denied under enforcing SELinux unless the path already carries a compatible context | A path you have already labeled yourself, e.g. with `chcon` |

```bash
podman run --rm -v "$PWD:/work:Z" docker.io/library/busybox:stable ls /work
```

Named volumes (`podman volume create`, then `-v volume-name:/path`) do not
need a `:Z`/`:z` suffix: Podman manages their SELinux labels itself.

### Rootless API socket (Docker-compatible tooling)

Disabled by default; this profile does not assume you need Docker-compatible
tooling. Pass `--api-socket` to `install-containers.sh` (or
`--containers-api-socket` to the top-level `./install.sh`) only if something
you use expects a Docker-style API socket:

```bash
./scripts/install-containers.sh --api-socket
```

This enables `podman.socket` in your own **user** systemd instance
(`systemctl --user enable --now podman.socket`), never the system-wide
socket. Being a `.socket` unit rather than a permanently running daemon, it
is socket-activated: `podman.service` only starts on the first connection
and can idle back down afterward. The socket is a Unix domain socket at
`$XDG_RUNTIME_DIR/podman/podman.sock`, reachable only by your user account;
it is never bound to a TCP port or exposed to the network.

**Security implications:** anything that can write to that socket path can
control every container your rootless user can — equivalent to shell access
as that user, though not to root, since the daemon itself still runs
unprivileged inside your subuid/subgid mapping. Do not add other local users
to your primary group or otherwise widen access to `$XDG_RUNTIME_DIR` if you
enable this.

Only export `DOCKER_HOST` if you actually run Docker-CLI-compatible tooling
against it; this profile does not set it for you:

```bash
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
```

### Differences from Docker worth knowing day to day

- **No background daemon by default.** Rootless Podman runs each container
  as a direct child process tree of the command that started it; there is no
  always-on `dockerd` unless you opt into `--api-socket`, and even then it is
  socket-activated rather than permanently running.
- **Rootless by default, not an opt-in flag.** `podman info`'s
  `Host.Security.Rootless` should read `true`; there is no `sudo podman`
  needed for the workflows this profile validates.
- **`podman-compose` and `podman compose` are two different things.**
  `podman-compose` is the installed Python provider; `podman compose` is
  Podman's own subcommand that calls it. Prefer `podman compose` so the
  provider stays swappable.
- **`:Z`/`:z` matter under SELinux enforcement**; Docker installations
  typically run without SELinux enforcement engaged the same way, so a
  Compose file copied from a Docker-only project may need these added to
  its bind mounts. Named volumes need no such suffix.
- **No `docker` command** unless you deliberately install `podman-docker`
  yourself; scripts hard-coded to shell out to `docker` need either that
  package or a per-project alias, not a global one from this profile.
- **Plain `depends_on` in a Compose file can hang `podman compose up -d`
  indefinitely** if the dependency is a fast-exiting one-shot container (a
  migration/seed/init step). `podman-compose` implements `depends_on` by
  running `podman wait --condition=...` against the dependency, and that
  wait blocks on a state *transition* — if the dependency already finished
  before the wait call starts, the transition it's waiting for will never
  happen again. This bit the profile's own smoke test during validation
  (see #89's history); the fix there was dropping `depends_on` and letting
  both services start concurrently, with the reachability check retrying
  until the seeded content actually appears. If you hit an unexplained hang
  on `podman compose up` with your own project, check for exactly this
  pattern before assuming a networking problem.

### Verification

`verify-containers.sh` checks `podman`/`podman-compose` are present,
`podman version`, rootless status and network backend from `podman info`,
the subuid/subgid mapping, and the API socket's state, then runs a smoke
test: pull, run, build, a `:Z`-labeled bind mount, a named volume, localhost
port publishing, container-to-container networking on a dedicated network,
and a two-service Compose project. Every smoke-test resource is uniquely
named per run and removed (containers, the built image, the volume, the
network, and temporary Compose/build directories) whether the run passes or
fails, so repeated verification never leaves containers, images, or volumes
behind. Pass `--skip-smoke-test` for an inspection-only run when you do not
want to touch the network or local container storage; `verify.sh`'s full
system check uses this so a routine `./install.sh` run does not repeat the
smoke test every time. `install-containers.sh` itself always runs the full
smoke test once, right after installing, so the end-to-end workflow is
proven immediately.

### Platform scope

This profile targets regular Fedora and Fedora WSL:

- **Fedora WSL**: supported (issue #93), with WSL-specific preconditions
  (systemd required, cgroup v2, unprivileged user namespaces) checked
  explicitly before installing, and WSL-specific differences (SELinux
  enforcement, networking-mode expectations, bind-mount guidance,
  `DOCKER_HOST` scope) documented rather than assumed equivalent to native
  Fedora. See "Podman containers under WSL" in the Fedora on WSL section
  above, including that section's validation-status note.
- **macOS**: supported only through the explicit `--platform macos
  --containers` profile. It uses a rootless Linux VM (`podman machine`) and a
  dedicated smoke test; it does not reuse Fedora systemd, SELinux, subuid, or
  host-networking assumptions. See [the macOS guide](docs/macos.md#optional-containers).
- **Parrot Security Edition CTF guest**: not installed and not appropriate
  to layer on automatically. The guest is an intentionally disposable
  offensive-security lab environment (see "Parrot Security Edition CTF VM"),
  and container tooling there should stay optional and never interfere with
  Parrot's own security catalogue.

The saved local state file is:

```text
~/.config/dotfiles/containers.conf
```

## Optional Tailscale networking profile

`--tailscale` (issue #109) installs the Tailscale client (the `tailscale`
CLI and the `tailscaled` service) as an optional networking profile. It is
not part of the default `./install.sh` path, appears in `--dry-run`, and can
be installed and reverified independently of the rest of the workstation:

```bash
./install.sh --tailscale
./scripts/install-tailscale.sh
./scripts/install-tailscale.sh --dry-run   # show the plan first
./scripts/verify-tailscale.sh              # re-run verification any time
```

This profile installs and enables the local client only. Everything
account/tailnet-specific — logging in, ACLs, exit nodes, subnet routes,
device tags, Tailscale SSH — is deliberately left to you, interactively,
outside this repository. Nothing here embeds a reusable auth key, an OAuth
client secret, a node key, or any tailnet policy.

### Package ownership

```text
tailscale       # tailscale CLI + tailscaled service
```

Fedora's own repositories do not carry Tailscale, so this profile adds
Tailscale's own DNF repository — `pkgs.tailscale.com/stable/fedora`, the
repository Tailscale's own install script uses for Fedora — via dnf5's
`config-manager addrepo` (installing the small `dnf5-plugins` package first
if `config-manager` isn't already available), rather than downloading a
standalone binary. Re-running the installer is a no-op once the repository
file exists: it is never re-added, and `dnf install`/`systemctl enable
--now` are naturally idempotent on their own.

### Service behavior

`tailscaled` is enabled and started with `systemctl enable --now tailscaled`,
the same as any other system service in this repository. **`tailscale up`
is never run automatically**, with no flags of any kind — not even an
unopinionated bare invocation — because that is the one command that
actually joins a tailnet, and this repository has no business choosing your
tailnet, your account, or your policy for you. Installing the profile always
leaves the machine in an installed-but-unauthenticated state.

### First interactive login

```bash
sudo tailscale up
```

This prints an interactive login link the first time; open it and
authenticate with your own identity provider/tailnet. Nothing here scripts
or automates that step. Once logged in, the machine stays connected across
reboots (`tailscaled` is enabled), and you never need to run `tailscale up`
again unless you explicitly log out or the node's key expires.

### Normal status commands

```bash
tailscale status     # this machine and its tailnet peers
tailscale ip -4       # this machine's Tailscale IPv4 address
tailscale ip -6       # this machine's Tailscale IPv6 address
tailscale version
```

### Disconnecting / logging out

```bash
tailscale down        # drop the tailnet connection; keep the node's identity
tailscale logout       # log out entirely; the node is removed from the tailnet
```

`down` is the everyday "stop routing traffic" toggle; `logout` is the
stronger action for retiring a machine from your tailnet. Neither is run by
this profile's installer or verifier.

### What is intentionally not automated

Per issue #109's own boundary, none of the following are set, enabled, or
even offered as a flag by this profile — they are account/tailnet policy,
not local-machine setup, and this repository has no cross-machine policy for
any of them yet:

- Authentication itself (`tailscale up` and the login it triggers)
- Reusable auth keys, OAuth client secrets, or node keys of any kind
- Tailnet ACLs, device tags, or any other admin-console policy
- Tailscale SSH
- Exit-node use or exit-node advertisement (`--exit-node`,
  `--advertise-exit-node`)
- Subnet routing (`--advertise-routes`)
- `--accept-routes` / `--accept-dns`
- MagicDNS-dependent behavior

If you want any of these, run the relevant `tailscale up`/`tailscale set`
command yourself and document the choice for your own tailnet; see
[Tailscale's firewall integration guide](https://tailscale.com/docs/integrations/firewalls)
for the additional `firewalld`/`iptables` configuration that subnet routing
and exit nodes need, which is out of scope for a basic client and therefore
not handled here.

### firewalld and SELinux

Nothing here touches `firewalld` or SELinux, and this profile does not
require it to. A plain Tailscale client only opens *outbound* HTTPS to
Tailscale's coordination server and then negotiates its own WireGuard
peer-to-peer/DERP-relayed traffic; Fedora's default firewalld zone already
permits outbound traffic and only blocks unsolicited inbound connections, so
a basic client needs no firewalld rule changes. (Exit nodes and subnet
routers do need `firewalld` masquerade/forwarding configuration — see the
link above — which is exactly the kind of tailnet-specific policy this
profile leaves to you.)

**Do not enable Tailscale SSH on a machine that keeps SELinux enforcing (the
default and the baseline this repository verifies on every `verify.sh`
run).** Tailscale SSH runs its SSH server logic inside `tailscaled` itself
rather than through the system's `sshd`/PAM stack, and SELinux's targeted
policy has no rule allowing that; the well-documented result is Tailscale SSH
sessions failing to open a shell under SELinux enforcement (see the
[upstream SELinux/Tailscale SSH
issue](https://github.com/tailscale/tailscale/issues/4914)) unless you
install a custom SELinux policy module or drop to permissive mode — neither
of which this profile will ever do for you. This is exactly the kind of
"clear repository-wide policy" gap the issue asks to leave alone rather than
paper over, so Tailscale SSH stays off by default and undocumented as a
one-line fix.

### Fedora WSL policy

`--tailscale` is intentionally **not** exposed under `--platform fedora-wsl`
(passing it fails fast with a clear error). The two realistic architectures
were weighed explicitly:

| | Tailscale on the Windows host only | Tailscale inside Fedora WSL as its own node |
|---|---|---|
| Tailnet identity | One node (the Windows machine) | A second, independent node sharing the same physical hardware |
| WSL networking | WSL2's NAT/mirrored networking already reaches anything the Windows host can reach, Tailscale peers included | Needs its own working outbound path through WSL2's virtualized network, duplicating what the host already has |
| systemd/service requirements | None inside WSL | Requires systemd as PID 1 in the distribution (same precondition as this repo's WSL containers profile) plus its own `tailscaled` |
| Duplicate identity | None | Two tailnet devices for one laptop, both needing their own approval/tags/eventual offboarding in the admin console |
| Operational value | Every WSL process already rides the host's tailnet membership for free | Only matters if WSL specifically needs a *different* tailnet identity than the host, e.g. exposing a WSL-only service under its own name |

For the common case — a developer wanting their traffic to reach tailnet
peers — Windows-host-only Tailscale already covers Fedora WSL for free,
with no second node to approve, tag, or eventually decommission. Running
Tailscale a second time inside the WSL distribution would only be
justified by a concrete need for WSL to present as an independent tailnet
device, which is a deliberate, tailnet-specific decision this repository
will not make for you. If you have that need, install Tailscale in Fedora
WSL the same way the native Fedora profile does (WSL2 with systemd support
can run `tailscaled` as a normal systemd service), but do so by hand; this
flag stays unsupported there until a concrete, documented use case argues
otherwise.

### macOS

Coordinated with issue #11/macOS workstation support: `--platform macos
--tailscale` installs Tailscale as the supported **Standalone** macOS app
(Homebrew cask `tailscale-app`, a sandboxed Network Extension app, not a
`tailscaled` systemd-style service — macOS has no systemd). Authentication
stays interactive by opening the app; nothing here scripts macOS's Network
Extension permission grant or the tailnet login. See [the macOS
guide](docs/macos.md#optional-tailscale) for the full command-line/CLI
integration notes and verification details.

The saved local state file is:

```text
~/.config/dotfiles/tailscale.conf
```

---

# AI-assisted development toolchain

AI-assisted development is an entirely optional workstation profile. **The
default `./install.sh`, with no AI-related flag, installs no Claude Code,
Codex, Herdr, GNHF, backpass, FirstMate, or any tool FirstMate requires.**
Select it explicitly:

```bash
./install.sh --ai                        # Claude Code + Herdr (core)
./install.sh --ai --codex                # + OpenAI Codex CLI
./install.sh --ai --firstmate            # + FirstMate and its required toolchain
./install.sh --ai --gnhf                 # + GNHF unattended overnight runs
./install.sh --ai --backpass             # + backpass instructions-file tuning
./install.sh --ai --codex --firstmate --gnhf --backpass   # all of the above
```

`--codex`, `--firstmate`, `--gnhf`, and `--backpass` require `--ai` and are
rejected otherwise (`--backpass` does not require `--firstmate` — the two
are independent). The profile is also independently callable and safe to
rerun:

```bash
./scripts/install-ai.sh [--codex] [--firstmate] [--gnhf] [--backpass] [--dry-run] [--validate]
```

`--dry-run` prints exactly which components would be installed and where,
without touching the filesystem; `--validate` runs verification only. Nothing
here authenticates any agent, pushes, merges, force-pushes, or deletes Git
branches, or requests API credentials — see "Authentication" below.

## Core agent: Claude Code

Claude Code (`anthropics/claude-code`) is the preferred/core coding agent.
Anthropic documents several install methods (native installer, Homebrew,
apt/dnf/apk, npm); this profile deliberately installs it through **mise's npm
backend** (`npm:@anthropic-ai/claude-code`), the same ownership model this
repository already uses for `npm:@mermaid-js/mermaid-cli` and `npm:neovim`.
This trades the native installer's silent background auto-update for one
consistent, mise-owned update/uninstall path shared with Codex and Herdr, and
avoids adding a second, Fedora-only package-management path (the `dnf` Claude
Code repository) that would not carry over to Fedora WSL or a future macOS
profile (see #11) unchanged.

Claude Code runs in any Git repository, including one checked out through
`git worktree`; it has no special worktree requirements of its own. See
"Worktree isolation for agent/crewmate work" below for how this repository
gives an agent a safe, isolated worktree rather than pointing it at your
primary checkout.

## Optional: OpenAI Codex CLI

`--codex` additionally installs the Codex CLI (`npm:@openai/codex`) through
the same mise ownership as Claude Code, so the two coexist without a second
install mechanism or a PATH ownership conflict. Codex is otherwise
independent of Claude Code: install either, both, or neither.

## Agent workspace/runtime: Herdr

[Herdr](https://herdr.dev) is a terminal multiplexer built specifically for
AI coding agents — persistent panes/tabs/workspaces, detach/reattach, and
agent-state awareness (working/idle/blocked) for Claude Code, Codex, and
similar tools. It is installed unconditionally with `--ai` (via `mise use -g
herdr`, matching mise's own documented install method), not gated behind
`--firstmate`, because it is useful the moment you have even a single Claude
Code session and is a single small, mise-owned binary rather than a heavy
dependency.

Responsibility split, so Ghostty, tmux, and Herdr never become three
competing layout/session systems:

```text
Ghostty -> terminal emulator / host window
tmux    -> lightweight shell/session multiplexing where still useful
Herdr   -> AI-agent workspace/orchestration (panes aware of agent state,
           detach/reattach, launching Claude Code/Codex workers)
```

Ghostty remains the normal terminal; this profile does not install a second
terminal emulator. Run `herdr` inside Ghostty in a project directory to start
a workspace, detach, and `herdr` again to reattach — see
[herdr.dev/docs](https://herdr.dev/docs) for the current pane/workspace
commands and socket API rather than duplicating fast-moving upstream option
lists here. Herdr's agent-aware panes make tmux's own session/window
management redundant for a multi-agent workflow; this repository does not
add glue code to bridge the two; use tmux (already installed, intentionally
thin) for ordinary shell multiplexing outside of agent work, and Herdr for
agent panes.

## Optional: FirstMate and its required toolchain

`--firstmate` installs [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate)
itself, plus every tool its own `docs/configuration.md` lists as required
(not merely nice-to-have) — all from the same author (Kun Chen), each
independently installable and independently useful on its own:

| Tool | What it's for | Owner |
|---|---|---|
| [firstmate](https://github.com/kunchenguid/firstmate) | the coordinator itself — a Claude-Code-compatible distribution, not a package | `git clone`/`git pull --ff-only` to `~/.local/share/firstmate` |
| [Treehouse](https://github.com/kunchenguid/treehouse) | pools isolated Git worktrees for crewmates (`get`/`enter`/`status`/`return`/`prune`/`destroy`/`lease`) | own install script, to `~/.local/bin/treehouse` |
| [No Mistakes](https://github.com/kunchenguid/no-mistakes) | local push-validation gate (see below) | own install script, to `~/.local/bin/no-mistakes` |
| [gh-axi](https://github.com/kunchenguid/gh-axi) | agent-ergonomic wrapper around the already-installed, already-authenticated `gh` CLI | mise, `npm:gh-axi` |
| [chrome-devtools-axi](https://github.com/kunchenguid/chrome-devtools-axi) | agent-ergonomic browser automation (launches its own headless Chrome; no separate browser install needed) | mise, `npm:chrome-devtools-axi` |
| [lavish-axi](https://github.com/kunchenguid/lavish-axi) | serves FirstMate's "rich-review" surfaces for HTML artifacts, locally | mise, `npm:lavish-axi` |
| [tasks-axi](https://github.com/kunchenguid/tasks-axi) | backlog/task manager FirstMate uses for crewmate handoff (edits a local `backlog.md`) | mise, `npm:tasks-axi` |
| [quota-axi](https://github.com/kunchenguid/quota-axi) | reports local LLM subscription quota windows so FirstMate's dispatch can decide whether to start/parallelize work; read-only, never mints/rotates credentials | mise, `npm:quota-axi` |

Requires `gh`, `tmux`, and `jq` (all already installed by the base profile);
can use Herdr as an alternative crew backend to tmux once installed above.
None of these need a separate account: `gh-axi`/`quota-axi` read your
already-authenticated `gh`/agent-CLI credentials, and the rest need no auth
at all.

FirstMate lets one coordinator session (Claude Code, by default here) talk to
you while it delegates isolated implementation work to crewmates it spawns
and supervises, each in its own Treehouse worktree, reporting plain outcomes
back to you. Registering a specific project and choosing one of its three
project modes (`direct-PR`, `local-only`, or `No Mistakes`, which runs full
CI validation before merge — very likely via the standalone No Mistakes tool
above, though FirstMate's docs don't explicitly confirm that link) is a
per-project, per-user decision this installer does not and cannot make
safely on your behalf. After installing:

```bash
cat ~/.local/share/firstmate/README.md    # follow FirstMate's own setup docs
gh auth login                             # if you have not already
treehouse --help                          # usable directly, with or without FirstMate
```

then launch a coordinator session there and register your project as
documented in that repository. This installer never runs `gh auth login`,
registers a project, `no-mistakes init` in any repository, or
`gh-axi`/`lavish-axi setup hooks` (their optional agent SessionStart hooks)
for you — all deliberate, manual, per-repository or per-preference steps.

### No Mistakes, in more detail

[No Mistakes](https://github.com/kunchenguid/no-mistakes) is a local Git
push-validation gate: instead of `git push origin <branch>`, you run
`git push no-mistakes <branch>`. That spins up a disposable worktree, runs
a validation pipeline, auto-applies safe mechanical fixes, escalates
anything that touches your intent for you to approve/fix/skip, and only
forwards to your real remote (opening a PR) once everything passes. It is
**strictly per-invocation** — nothing happens to a normal `git push`, and it
never intercepts one. Setup (`no-mistakes init`, which creates a local bare
repo under `~/.no-mistakes/repos/` and adds the `no-mistakes` remote) is
per-repository and always manual; installing this profile only puts the
`no-mistakes` binary on `PATH`.

Each tool above is installed through exactly one mechanism: mise for the
five `*-axi` npm packages (same ownership as Claude Code/Codex/GNHF), and an
official install script for Treehouse/No Mistakes (neither has a mise
registry entry or an OS package). `verify-ai.sh` checks all seven the same
way it checks everything else in this profile — mise ownership for the
mise-managed ones, PATH-resolution-to-the-installed-copy for the other two.

## Optional: GNHF unattended overnight agent orchestrator

`--gnhf` additionally installs
[GNHF](https://github.com/kunchenguid/gnhf) ("Good Night, Have Fun") through
mise (`npm:gnhf`), the same ownership as Claude Code/Codex. It has no
relation to FirstMate, Herdr, or Treehouse, and needs no separate account —
it shells out to whichever already-authenticated agent CLI you point it at
(`--agent`, default `claude`) in non-interactive mode.

**Read this before your first run.** GNHF runs a coding agent through many
iterations completely unattended: each iteration gets one objective-directed
change, and on success it **commits automatically with no human checkpoint**
— you review the result afterward, not each step. A failed iteration is
rolled back with `git reset --hard` (scoped to GNHF's own commits). There is
no sandboxing beyond `--max-iterations`/`--max-tokens` caps and an abort
after repeated consecutive failures: the agent has the same permissions your
normal Claude Code/Codex session would.

Two defaults keep this compatible with this profile's non-destructive
posture despite that:

- By default GNHF works on a new local `gnhf/<slug>` branch in your repo,
  not your current checkout (an isolated worktree is available via its own
  `--worktree` flag).
- By default GNHF **never pushes**. Pushing is strictly opt-in via GNHF's
  own `--push` flag, which this installer never adds for you and does not
  wrap or default on in any way.

So the "no autonomous push without explicit action" invariant holds even
with GNHF installed — but "many unsupervised commits before you look" is a
real, different trust model from the rest of this profile, and is exactly
why GNHF is its own opt-in flag rather than bundled with core `--ai`. Treat
"point GNHF at an objective and let it run overnight" as a deliberate
choice each time, the same way you would `--hardening` or a raw `sudo`
command — not something to leave on a machine that other people can queue
work on. Config lives at `~/.gnhf/config.yml` (created on first run,
untracked, machine-local).

## Optional: backpass instructions-file tuning

`--backpass` additionally installs
[backpass](https://github.com/kunchenguid/backpass) and
[acpx](https://github.com/openclaw/acpx) through mise (`npm:backpass`,
`npm:acpx`), plus `lavish-axi` if it isn't already installed (it's shared
with `--firstmate`; declared once either way, never twice). Unlike every
other subcomponent above, **it is independent of `--firstmate`** — no real
integration between them exists beyond a shared dependency on `lavish-axi`
for review UIs, so `--ai --backpass` alone works fine.

backpass reads agent session transcripts (Claude, Codex, Pi, OpenCode,
Grok, Cursor CLI, Hermes) directly off disk, distills them (96–99% token
reduction) locally, and proposes evidence-backed edits to your
`AGENTS.md`/`CLAUDE.md` — one card per edit, with the diff, the evidence
quotes, and their sources, served through `lavish-axi`. **`backpass apply`
is the only command that writes anything**, and only for edits you
individually ACCEPT; rejections are remembered and not re-proposed unless
new evidence appears.

What to know before your first run:

- It is not purely offline: the distilled (secret-redacted) trace still
  travels over the network, through `acpx`, to whichever model you
  configure. Same trust boundary as the agent CLI you already use, not a
  new one — but not zero-exposure either.
- Its default model routing can call a **non-Claude model** for analysis
  and/or synthesis (with a Claude fallback). Pin one provider explicitly
  with `--analysis-agent`/`--synthesis-agent` if that matters to you; this
  installer does not change backpass's own defaults.
- It edits the single file that steers every future agent session in a
  repository. The mandatory review gate is real, but it's still worth
  reading each diff carefully rather than rubber-stamping — that's on you,
  not the tool.
- Setup (`backpass init`) is per-repository and always manual; installing
  this profile only puts `backpass`/`acpx` on `PATH`.

### Other Kun Chen tools evaluated but not installed

One more tool from the same ecosystem came up during review and is not
installed by this profile:

- **[AXI](https://github.com/kunchenguid/axi)** (`kunchenguid/axi`) itself
  is not a tool to install — it is a design specification (10 principles)
  plus a catalog of 70+ community reference implementations (Jujutsu,
  npm/PyPI/Cargo, cloud platforms, Slack/Notion/Jira, and more) for
  building token-efficient, agent-ergonomic CLI wrappers. `gh-axi`,
  `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, and `quota-axi` above
  are the reference implementations this profile actually uses (because
  FirstMate requires them, or because `--backpass` needs `lavish-axi`); the
  rest of the catalog is not — install one yourself only if you personally
  use that specific tool a lot with an agent (for example
  `npm install -g gh-axi` standalone, without `--firstmate`, works fine
  against your existing `gh`).

## Non-destructive defaults

None of this profile's own tooling pushes branches, merges pull requests,
force-pushes, or deletes branches on its own. No Mistakes (installed with
`--firstmate`) only ever acts when you explicitly run
`git push no-mistakes <branch>` instead of your normal push — it never
intercepts a plain `git push`, and its own setup (`no-mistakes init`) is
per-repository and manual, never run by this installer. FirstMate's own
project modes gate publication behind an explicit captain decision
(`local-only` waits for an approved fast-forward merge; `direct-PR` opens a
PR for human review; its `No Mistakes` mode additionally runs full CI, very
likely via that same tool, before merge) — this repository does not enable
an autonomous push/merge mode by default, and installing this profile does
not change any existing Git signing,
authentication, or identity configuration (see "Git, SSH and GitHub
authentication" and "Choices a user must make" above/below). GNHF, if
selected, defaults to committing on its own local `gnhf/<slug>` branch and
never pushes; pushing is opt-in via GNHF's own `--push` flag, which this
installer never adds on your behalf (see "Optional: GNHF" above for the
part of its behavior — unsupervised, per-iteration commits — that this
invariant does not cover). Prefer Claude Code and Codex's own review/PR-
oriented workflows, with a human decision at the publication/merge
boundary, as shown in the normal usage flow below.

## Normal usage

```text
open repository
  -> start/reattach a Herdr workspace (or a plain tmux/Ghostty session)
  -> use Claude Code directly, or start a FirstMate coordinator session
  -> delegate isolated work into a Treehouse worktree (directly, or through
     FirstMate's own crewmates), or a plain `git worktree` if Treehouse
     is not installed
  -> review the resulting diff and run tests
  -> create a PR (gh pr create, or let Claude Code/Codex/FirstMate open one)
  -> a human decides whether to merge
```

## Authentication

Never committed to this repository: API keys, OAuth tokens, provider
credentials, GitHub tokens, or agent session state. Authenticate each tool
interactively, on the machine, after installing:

- **Claude Code**: run `claude`, follow the browser login prompt (or set
  `ANTHROPIC_API_KEY` for API-key auth). State lives in `~/.claude/` and
  `~/.claude.json`, untracked and machine-local.
- **Codex**: run `codex`, choose "Sign in with ChatGPT" (or configure an
  OpenAI API key). State lives under `~/.codex/`, untracked and
  machine-local.
- **FirstMate**: uses your already-authenticated `gh` (`gh auth login`); it
  does not manage its own separate credentials.
- **GNHF**: no separate account; it shells out to your already-authenticated
  `claude` (or another configured `--agent`). Its own config lives at
  `~/.gnhf/config.yml`, untracked and machine-local.
- **backpass**: no separate account; every model call goes through `acpx`
  to a harness you have already authenticated. Per-repository state lives
  under a git-excluded `.backpass/` directory (see `.git/info/exclude`),
  untracked and machine-local.

Revoke access by signing out of each tool, or by deleting its state
directory above; none of it is readable from this repository.

## Verification

```bash
./scripts/verify-ai.sh
```

checks that Claude Code, Herdr, and (if selected) Codex/GNHF/gh-axi/
chrome-devtools-axi/lavish-axi/tasks-axi/quota-axi/backpass/acpx resolve on
PATH to the mise-managed copy this profile installed rather than a second
install shadowing it elsewhere on PATH (catching duplicate
npm/Homebrew/native-installer ownership of the same tool), and, if
selected, that FirstMate is cloned with `gh`, `tmux`, and `jq` present, and
that Treehouse/No Mistakes resolve to the copies this profile installed at
`~/.local/bin/treehouse` and `~/.local/bin/no-mistakes`.
`platforms/fedora/scripts/verify.sh` (and the Fedora WSL equivalent) run
this automatically whenever the AI profile's state file is present, and
separately confirm that **no** AI-owned file exists when it is not.

## Ownership summary

| Component | Owner | Update |
|---|---|---|
| Claude Code | mise (`npm:@anthropic-ai/claude-code`) | `mise upgrade` |
| Codex CLI | mise (`npm:@openai/codex`) | `mise upgrade` |
| Herdr | mise (registry) | `mise upgrade` |
| GNHF | mise (`npm:gnhf`) | `mise upgrade` |
| backpass, acpx | mise (`npm:backpass`, `npm:acpx`) | `mise upgrade` |
| FirstMate | `git clone`/`git pull --ff-only` to `~/.local/share/firstmate` | rerun `--firstmate` |
| Treehouse | own install script, to `~/.local/bin/treehouse` (no mise registry entry) | rerun `--firstmate` |
| No Mistakes | own install script, to `~/.local/bin/no-mistakes` (no mise registry entry) | rerun `--firstmate` |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi | mise (`npm:<name>`), all with `--firstmate` | `mise upgrade` |
| lavish-axi | mise (`npm:lavish-axi`), with `--firstmate` and/or `--backpass` (declared once either way) | `mise upgrade` |

See "AI agent tooling" under "Package ownership" below for how this avoids
duplicate installs of the same tool. Every mise-managed tool above is
declared in an **untracked, machine-local** mise config file, not the tracked
`~/.config/mise/config.toml` this repository always installs:

```text
~/.config/mise/conf.d/ai.toml
```

mise merges every `*.toml` file under `~/.config/mise/conf.d/` alongside its
main global config, so this file adds Claude Code/Codex/Herdr to mise's view
without the default, always-applied mise config ever gaining an AI-related
dependency. `install-ai.sh` writes and owns this file; deleting it and
rerunning the AI profile recreates it.

## Platform scope

- **Fedora**: primary reference path; validated with Ghostty, Zsh, tmux,
  Git/GitHub CLI, and LazyVim, and compatible with the hardening, Podman,
  and VM-host profiles and this repository's existing Git signing/auth setup
  (none of that is touched by `--ai`).
- **Fedora WSL**: supported with the same `--ai`/`--codex`/`--firstmate`
  flags. The desktop, hardware, Sway, and VM-host/guest profiles remain out
  of scope for WSL, but the AI profile has no GUI or hardware dependency.
  Fedora WSL's existing PATH policy (see "PATH and Windows interoperability"
  above) already ensures a Windows-installed `claude.exe`/`codex.exe` cannot
  shadow the Linux-native, mise-managed copy; `verify-ai.sh` additionally
  checks for exactly that.
- **macOS** (#11): not implemented here. `common/install-ai.sh` and
  `common/verify-ai.sh` contain no Fedora-specific commands (checked by
  `tests/test-platform-boundary.sh`), so a macOS installer can call them
  directly once mise, `gh`, and `tmux` are provisioned there.
- **Parrot Security Edition CTF guest**: deliberately excluded, matching this
  guest's existing "no AI tooling by default" posture (see "Parrot Security
  Edition CTF VM" above): install or invoke AI tooling there only as a
  conscious per-lab decision after confirming that challenge data may leave
  the guest.

The saved local state file is:

```text
~/.config/dotfiles/ai.conf
```

---

# Package ownership

Avoid installing the same tool through multiple package managers.

## macOS / Homebrew

The Apple Silicon profile uses Homebrew only at `/opt/homebrew` for native
machine tools, shell plugins, Ghostty, and AeroSpace. mise continues to own the
portable language runtimes and CLIs. OCaml remains split between a
Homebrew-owned `opam` binary/build prerequisites and an opam-owned compiler
switch. The exact inventory and duplicate-architecture policy are documented
in the [macOS package-ownership table](docs/macos.md#3-package-ownership).

## Fedora / DNF

Machine-level and OS-integrated tools:

```text
bat
curl
eza
fd
fzf
gh
git
git-delta
libicu
neovim
openssh-clients
ripgrep
ShellCheck
sqlite
sqlite-devel
stow
tmux
wl-clipboard
zoxide
zsh
zsh-autosuggestions
zsh-syntax-highlighting
```

The optional Sway session adds Sway, Waybar, Fuzzel, Mako, swaylock,
swayidle, swaybg, desktop portals, a polkit agent, clipboard and screenshot
utilities, hardware-key utilities, and the small GUI control tools used by the
bar. It includes Fedora's `sway-systemd` integration so the Sway session
activates the graphical-session lifecycle required by desktop portals. It also
runs standard XDG autostart entries through `dex-autostart`, so
application preferences such as 1Password's **Start at Login** work in Sway as
they do in KDE. Waybar provides the StatusNotifier tray required by background
applications, while GTK handles general desktop portals and the wlroots backend
handles screenshots and screen sharing. These packages remain Fedora/DNF-owned.

The optional OCaml profile adds the `opam` binary plus `bzip2`,`gcc`, `gcc-c++`, `make`,
`m4`, `patch`, `pkgconf-pkg-config`, `unzip`, and `bubblewrap`. These are native
package/build prerequisites only; DNF does not own the selected OCaml compiler
or the OCaml Platform tools.

The optional desktop-tools profile adds `gimp`, `pdfarranger`, `skanpage`, and
`xdg-utils`. It reuses the Fedora KDE baseline's Gwenview, Okular, and Ark
instead of installing alternatives, installing one only if it is genuinely
missing. See [Optional desktop-tools profile](#optional-desktop-tools-profile).

The optional containers profile adds `podman` and `podman-compose`. It
deliberately does not add Buildah, Skopeo, Docker Engine, or a `docker`
alias. See [Optional Podman container development
profile](#optional-podman-container-development-profile).

The optional Tailscale profile adds `tailscale` (the CLI and `tailscaled`)
from Tailscale's own DNF repository, not Fedora's. See [Optional Tailscale
networking profile](#optional-tailscale-networking-profile) and "Tailscale
package repository" below.

## Terra RPM repository

The reference setup uses Terra packages for:

```text
ghostty
mise
starship
```

These remain RPM-owned. mise itself is **not** installed by mise.

## Tailscale package repository

The optional `--tailscale` profile enables Tailscale's own DNF repository
(`pkgs.tailscale.com/stable/fedora`), added via dnf5's `config-manager
addrepo`, and installs only `tailscale` from it. This is Tailscale's
currently supported Fedora installation path, the same one its own install
script uses, rather than a standalone downloaded binary. See [Optional
Tailscale networking profile](#optional-tailscale-networking-profile).

## RPM Fusion repositories

The optional desktop-tools profile enables RPM Fusion's free and nonfree
repositories, reusing the same `ensure_rpm_fusion_repositories` helper the
ASUS hardware profile already uses for firmware packages, and installs `mpv`
from there. This is the standard Fedora community path to full multimedia
codec support and remains RPM/DNF-owned; no other profile depends on it.

## Parrot / APT

The `parrot-ctf` profile installs only shell/editor/Python prerequisites and
`qemu-guest-agent`/`spice-vdagent`. Parrot Security Edition's existing security
packages and repositories remain untouched and APT-owned. Debian's `batcat`
and `fdfind` command names are exposed as `bat` and `fd` through two small
Parrot-only wrappers. Starship is APT-owned; mise is installed in
`~/.local/bin` from its upstream installer and installs only `uv` from the
Parrot manifest.

## mise

The tracked configuration is:

```text
~/.config/mise/config.toml
```

The current user-level developer toolset includes:

```text
dotnet
node
python
uv

lazygit
ast-grep
tree-sitter

dotnet:EasyDotnet
npm:@mermaid-js/mermaid-cli
npm:neovim
pipx:pynvim
```

`mise install` installs what is declared in the tracked config; the install script does not duplicate the tool list.

## AI agent tooling

Optional; installed only by `--ai` (see "AI-assisted development toolchain"
above for daily usage). Declared in a separate, **untracked**, machine-local
mise config file so the tracked `~/.config/mise/config.toml` above never
gains an AI-related dependency:

```text
~/.config/mise/conf.d/ai.toml
```

| Component | Owner |
|---|---|
| Claude Code | mise, `npm:@anthropic-ai/claude-code` |
| Codex CLI (optional) | mise, `npm:@openai/codex` |
| Herdr | mise, registry entry `herdr` |
| GNHF (optional, requires `--gnhf`) | mise, `npm:gnhf` |
| backpass, acpx (optional, requires `--backpass`) | mise, `npm:backpass`, `npm:acpx` |
| FirstMate (optional, requires `--firstmate`) | `git clone`/`git pull --ff-only`, no package manager upstream |
| Treehouse (optional, requires `--firstmate`) | own install script to `~/.local/bin/treehouse`, no mise registry entry or OS package |
| No Mistakes (optional, requires `--firstmate`) | own install script to `~/.local/bin/no-mistakes`, no mise registry entry or OS package |
| gh-axi, chrome-devtools-axi, tasks-axi, quota-axi (optional, require `--firstmate`) | mise, `npm:<name>` each |
| lavish-axi (optional, requires `--firstmate` and/or `--backpass`) | mise, `npm:lavish-axi` (declared once regardless of which flag(s) select it) |

Each tool is installed through exactly one mechanism above; this repository
does not additionally install any of them through Homebrew, a global `npm
install -g`, or a native/OS-package installer, so there is never a duplicate,
competing copy on `PATH`. `verify-ai.sh` checks this by confirming each
mise-managed command resolves to the same binary mise itself reports
managing, and that Treehouse resolves to the copy this profile installed.

## opam

The optional OCaml profile deliberately uses the ecosystem's switch model:

| Component | Owner |
|---|---|
| `opam` binary and native build prerequisites | Fedora/DNF |
| OCaml compiler and versioned switch | opam |
| `dune`, `utop`, `ocaml-lsp-server`, `ocamlformat`, `earlybird` | opam, in the same switch as the compiler |
| OCaml Treesitter parser | `nvim-treesitter`, only when opam is present |
| Project libraries and test dependencies | The project's opam switch and `.opam` files |

Neither mise nor Mason installs OCaml, dune, OCaml LSP, OCamlFormat, or utop.
Keeping the compiler and editor tools together avoids the version mismatch that
can occur when Mason installs `ocaml-lsp-server` independently of an opam
switch.

## Mason

Mason owns the editor-facing binaries below. This is the complete expected
inventory, derived from the tracked LazyVim extras and local plugin specs. The
canonical package names live in `nvim-lazyvim/.config/nvim/mason-packages.txt`:

| Mason package | Declared by | Responsibility |
|---|---|---|
| `angular-language-server` | LazyVim Angular extra | Angular template and framework language support |
| `debugpy` | LazyVim Python extra | Python debug adapter used by `nvim-dap-python` |
| `eslint-lsp` | LazyVim ESLint extra | Editor-to-project ESLint bridge |
| `js-debug-adapter` | LazyVim TypeScript extra when DAP is enabled | JavaScript and TypeScript debugging |
| `json-lsp` | LazyVim JSON extra | JSON language support |
| `lua-language-server` | LazyVim core | Lua language support for Neovim configuration |
| `marksman` | LazyVim Markdown extra | Markdown links, references and document navigation |
| `netcoredbg` | `lua/plugins/dotnet.lua` | Debug adapter binary used by EasyDotnet |
| `pyright` | LazyVim Python extra | Python language server and type checking |
| `roslyn` | `lua/plugins/dotnet.lua` | C# language server used by `roslyn.nvim` |
| `ruff` | LazyVim Python extra | Editor diagnostics and formatting using project configuration |
| `shfmt` | LazyVim core | Editor formatting for shell files |
| `stylua` | LazyVim core | Editor formatting for Lua files |
| `texlab` | LazyVim TeX extra | TeX language support |
| `vtsls` | LazyVim TypeScript extra, imported by Angular | TypeScript language server using the workspace TypeScript SDK |
| `yaml-language-server` | LazyVim YAML extra | YAML language support |

The installer first restores the locked lazy.nvim plugin set and then runs a
blocking, time-limited `:MasonInstall` for any missing packages. This avoids
depending on language-specific plugins and filetypes loading during an
interactive first launch. Mason's normal `ensure_installed` configuration uses
the same inventory, so later interactive starts retain the expected behavior.
`scripts/verify.sh` fails when an intended package is missing and warns about
additional Mason packages so stale or manually installed tools can be reviewed
instead of silently acquiring a second owner.

## Project-local tooling

Project formatters, linters, compilers, and repository-specific CLIs should remain project-owned.

Examples:

### .NET repository

```text
CSharpier
dotnet-ef
```

These belong in `.config/dotnet-tools.json`.

### Angular / TypeScript repository

```text
Prettier
ESLint
angular-eslint
typescript-eslint
TypeScript
Karma / other project test runner
```

These belong in `package.json`.

### Python repository

```text
pytest
Ruff
application and library dependencies
```

These belong in `pyproject.toml` and are resolved into a project-local `.venv`
with `uv`. Mason's Ruff installation is editor-only; CLI and CI execution uses
the project-declared version.

### OCaml repository

Application libraries and test dependencies belong in the project's `.opam`
files, with build structure in `dune-project` and `dune` files. opam resolves
them into the selected switch; the workstation profile supplies only the
compiler and common development tools.

---

# GNU Stow layout

Each top-level configuration directory is a Stow package:

```text
bat/
bin/
fzf/
ghostty/
git/
lazygit/
mise/
nvim-lazyvim/
starship/
tmux/
zsh/

platforms/fedora/stow/
├── theme-assets/   # shared KDE/Sway wallpapers
├── theme-hooks/    # Fedora desktop response to `theme`
├── zsh-platform/   # Fedora package paths for Zsh plugins
├── sway/           # only stowed with --sway
└── waybar/         # only stowed with --sway
```

Stow is run with `--no-folding`.

This is intentional. Individual tracked files are linked into normal directories so tracked and machine-local files can coexist.

Example:

```text
~/.config/git/
├── config          -> dotfiles/git/...
├── themes/...      -> dotfiles/git/...
├── local           # local, not tracked
└── drdk            # local, not tracked
```

---

# Machine-local state

The following files are intentionally outside the repository:

```text
~/.config/dotfiles/
├── theme
├── hardware.conf
├── ghostty.conf
├── git-theme
├── tmux-theme.conf
├── sway-theme.conf
├── waybar-theme.css
├── fuzzel.ini
├── mako.conf
└── swaylock.conf

~/.config/git/
├── local
└── drdk

~/.config/sway/
└── local.conf       # output names, positions, modes, and scaling
```

The shared Ghostty, Git, and tmux theme files are produced by the portable
theme state. The Sway, Waybar, Fuzzel, Mako, and swaylock files are produced by
the Fedora theme hook. `hardware.conf` is created only after an optional
hardware profile has been installed; it records the selected model and
verification requirements.

The Git files contain user-specific identity and optional authentication/signing configuration.

When upgrading from a version that tracked these files accidentally,
`scripts/setup-local.sh` replaces the old Stow links with private local files
before the remaining dotfiles are restowed.

---

# Catppuccin theming

The repository installs all four Catppuccin flavors and uses one local selector.

Default:

```text
macchiato
```

Accent where applicable:

```text
mauve
```

## KDE

All four global themes are installed with:

- Mauve accent
- Classic window decoration
- Catppuccin cursor theme

The pinned upstream installer always applies a theme in its non-interactive
mode. The Fedora installer suppresses those intermediate apply calls while it
installs all four flavours, then the shared `theme` command applies the chosen
flavour and its matching wallpaper once as the final desktop state.

Known Plasma identifiers:

| Flavor | Global theme | Color scheme | Cursor |
|---|---|---|---|
| Latte | `Catppuccin-Latte-Mauve` | `CatppuccinLatteMauve` | `catppuccin-latte-mauve-cursors` |
| Frappé | `Catppuccin-Frappe-Mauve` | `CatppuccinFrappeMauve` | `catppuccin-frappe-mauve-cursors` |
| Macchiato | `Catppuccin-Macchiato-Mauve` | `CatppuccinMacchiatoMauve` | `catppuccin-macchiato-mauve-cursors` |
| Mocha | `Catppuccin-Mocha-Mauve` | `CatppuccinMochaMauve` | `catppuccin-mocha-mauve-cursors` |

## Ghostty

All four official Ghostty theme files are tracked under:

```text
~/.config/ghostty/themes/
```

The tracked Ghostty configuration has Macchiato as a fallback and optionally includes:

```text
~/.config/dotfiles/ghostty.conf
```

## Neovim

Catppuccin is installed through `lazy.nvim`, because LazyVim itself uses `lazy.nvim`.

The configuration does **not** use `vim.pack`.

Available colorschemes:

```vim
:colorscheme catppuccin-latte
:colorscheme catppuccin-frappe
:colorscheme catppuccin-macchiato
:colorscheme catppuccin-mocha
```

Neovim reads the machine-local theme state on startup and checks it again on `FocusGained`.

## Starship

The source prompt configuration lives in:

```text
starship/.config/starship/template.toml
```

Four tracked runtime configurations are generated:

```text
catppuccin-latte.toml
catppuccin-frappe.toml
catppuccin-macchiato.toml
catppuccin-mocha.toml
```

Regenerate after changing the template:

```bash
./scripts/update-starship-themes.sh
```

The shell selects one using `STARSHIP_CONFIG`.

The current prompt is based on Starship's Catppuccin Powerline preset, with:

- `.NET` added to the runtime section
- the command prompt on a second line
- command-duration notifications currently enabled

The Powerline layout may be simplified later.

## fzf

All four official Catppuccin fzf snippets are tracked.

Zsh selects:

```text
catppuccin-fzf-${DOTFILES_THEME}.sh
```

The `Ctrl-R` configuration adds:

- reverse layout
- border
- command preview
- Bat syntax highlighting in the preview

## Bat

Bat uses its packaged Catppuccin themes.

The active flavor is selected using `BAT_THEME`.

## Delta

The official Catppuccin Delta configuration is tracked as a Git config fragment.

The active feature is provided by:

```text
~/.config/dotfiles/git-theme
```

## Lazygit

The functional Lazygit configuration remains separate from theme configuration.

The official mergeable Catppuccin theme files are tracked for all four flavors.

Zsh sets `LG_CONFIG_FILE` to merge the normal config and selected theme.

## tmux

Catppuccin's tmux plugin is **not vendored inside the dotfiles repository**.

It is installed to:

```text
~/.local/share/tmux/plugins/catppuccin
```

by:

```bash
./scripts/install-tmux-theme.sh
```

## Sway desktop

On Fedora, a platform hook makes the portable `theme` command also update Sway,
Waybar, Fuzzel, Mako, swaylock, the flavour-matched wallpaper, and the pointer
cursor theme. A running Sway session is reloaded automatically; new Fuzzel
invocations read the new generated configuration. Ghostty is reloaded through
its systemd user service when active, or directly with Ghostty's `SIGUSR2`
reload signal when launched from Sway. When a Sway session is actually
running, KDE desktop integration is skipped entirely, since Plasma's DBus
interface has nothing to talk to under Sway.

The generated Sway configuration sets `seat * xcursor_theme` to the
flavour-matched Catppuccin cursor theme. Cursor theme files are only
installed by the optional KDE profile's `install-kde-theme.sh`
(see [KDE](#kde)); on a Sway-only install (`./install.sh --sway` without
`--kde`), the directive references a theme that is not present on disk and
the pointer falls back to the system default.

Pass `--preserve-wallpaper` to keep the current KDE or Sway desktop wallpaper
while applying those theme changes. KDE's lock screen and Swaylock remain
flavour-controlled.

The four tracked 3840x2160 wallpapers form a flavour-matched tropical-island
day-to-night cycle adapted from the MIT-licensed Catppuccin wallpaper
collection. They are shared Fedora desktop theme assets used by both KDE and
Sway. Swaylock uses a separately tracked blurred and darkened derivative of the
active wallpaper. The exact upstream revision and license are recorded beside
the assets and in `LICENSES/Catppuccin.txt`.

---

# Keyboard layouts

Fedora KDE and Sway use the same two-layout workflow:

| Shortcut | Action |
|---|---|
| `Super+Alt+K` | Switch between US and Danish keyboard layouts |

The Sway profile tracks `us,dk` for `input type:keyboard`, so the setting also
applies to external keyboards connected after login. Waybar's native
`sway/language` module shows the active XKB layout as the compact code `us` or
`dk`, updates from Sway input events immediately, and can also be clicked to
switch layouts.

Plasma 6 already uses `Meta+Alt+K` as the default shortcut for **Switch to Next
Keyboard Layout**. Layout selection remains a one-time desktop preference so
the dotfiles do not overwrite other settings in `kxkbrc` or the user's global
shortcuts:

1. Open **System Settings → Keyboard → Layouts** and enable layout management.
2. Add **English (US)** followed by **Danish**, with no layout variants unless
   intentionally needed.
3. Open **Configure Switching…**, keep **Switching layout affects** set to
   **All windows**, and confirm **Change layout** is `Meta+Alt+K`.
4. Apply the changes. Plasma's keyboard-layout tray item provides the active
   layout indicator.

These entries are part of the shared KDE/Sway keyboard workflow and should be
included when the printable profile cheat sheets from issue #72 are generated.

---

# Optional Sway session

`./install.sh --sway` produces a complete daily-driver session while leaving
KDE and KWin untouched. Select **Sway (dotfiles)** from the display manager
when desired; the installer deliberately does not change the default login
session.

The session uses Sway's native container tree, no gaps, and thin Catppuccin
borders. Nine workspaces form this conceptual grid:

| | | |
|---|---|---|
| 1 | 2 | 3 |
| 4 | 5 | 6 |
| 7 | 8 | 9 |

Directional workspace movement wraps at every edge. For example, moving left
from workspace 1 selects 3, and moving up from workspace 1 selects 7.

| Shortcut | Action |
|---|---|
| `Super+Enter` | Open Ghostty |
| `Super+P` | Open Fuzzel |
| `Super+H/J/K/L` | Focus a container |
| `Super+Shift+H/J/K/L` | Rearrange a container |
| `Super+Ctrl+H/J/K/L` | Navigate the wrapped workspace grid |
| `Super+1..9` | Select a numbered workspace |
| `Super+Shift+1..9` | Move a container to a workspace |
| `Super+F` | Toggle fullscreen |
| `Super+Shift+C` | Close the focused window |
| `Super+Shift+X` | Lock the session |
| `Super+Alt+K` | Switch between US and Danish keyboard layouts |
| `Super+N` / `Super+Shift+N` | Dismiss / restore a Mako notification |
| `Super+Shift+V` | Open clipboard history |
| ASUS screenshot key / `Print` | Select and annotate a screenshot region |
| `Shift+Print` | Save the current output to `~/Pictures/Screenshots` |

Waybar remains visible and shows workspaces, the focused title, a compact system
tray, power profile, active keyboard layout, network, Bluetooth, audio, battery,
and clock. Clicking the layout code switches layouts; clicking network,
Bluetooth, or audio opens `nm-connection-editor`, `blueman-manager`, or
`pavucontrol`. Notifications use Mako. The Xwayland Video Bridge remains
available for legacy application screen sharing, but its helper window is kept
in Sway's hidden scratchpad instead of occupying a tile.

Swayidle locks after 10 minutes and powers displays off after 15 minutes. Input
turns the displays back on. It intentionally never suspends or hibernates the
machine; system power policy remains outside the compositor configuration.

Output discovery is automatic. Put machine-specific arrangements in the
untracked file created by the installer:

```text
~/.config/sway/local.conf
```

Find current output names with `swaymsg -t get_outputs`, then add `output`
directives for laptop-only, USB-C, HDMI, or docked layouts. The tracked config
does not assume stable connector names. A fresh `ga402xz` installation writes
`output eDP-1 scale 1` to this local file; existing local overrides are never
replaced.

On the NVIDIA-equipped GA402XZ, keep Plasma available as the recovery and
hardware-compatibility session. Sway works best when the AMD iGPU drives the
desktop; HDMI and the right USB-C port may depend on the NVIDIA dGPU. This
configuration does not alter the MUX or change GPU mode. The installer adds a
`Sway (dotfiles)` login session which passes `--unsupported-gpu` only when the
proprietary `nvidia_drm` module is loaded, because Sway 1.11 otherwise refuses
to start. If an external output is absent, log back into Plasma and inspect the
current ASUS/NVIDIA state before changing local output rules.

---

# Ghostty

Ghostty is deliberately kept fairly minimal.

Current functional configuration includes:

```text
Zsh shell integration
cursor integration
sudo integration
title integration
SSH environment handling
SSH terminfo handling
Catppuccin theme
```

Ghostty is the primary **local layout manager**:

- tabs
- splits
- terminal window layout
- terminal scrollback

tmux is not intended to duplicate this locally.

## Clipboard

On Linux/Wayland:

```text
Ctrl-Shift-C   copy
Ctrl-Shift-V   paste
```

Inside Neovim, prefer Neovim registers for editor content.

The system clipboard register is:

```vim
"+
```

Examples:

```vim
"+yy
"+p
```

---

# tmux

tmux is intentionally a thin persistence/session layer.

Primary use cases:

- persistent local sessions
- long-running processes
- remote SSH sessions
- recovering work after terminal disconnects

Ghostty remains the preferred local layout/split manager.

Useful commands:

```bash
tmux new -As valhal
tmux ls
tmux attach -t valhal
tmux kill-session -t valhal
```

Important default keys:

```text
Ctrl-b d    detach
Ctrl-b s    choose session
Ctrl-b $    rename session
Ctrl-b [    copy/scroll mode
Ctrl-b ?    show tmux key bindings
```

The standard `Ctrl-b` prefix is intentionally preserved.

---

# Zsh

The startup model is deliberately simple.

## `~/.zshenv`

Only early environment configuration belongs here:

```zsh
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
export PATH="$HOME/.local/bin:$PATH"
```

## `~/.config/zsh/.zshrc`

Contains:

- history configuration
- local Catppuccin flavor selection
- Lazygit/Bat/fzf/Starship theme selection
- zoxide
- fzf integration
- autosuggestions
- aliases
- mise activation
- Starship
- syntax highlighting

The configuration intentionally avoids Oh My Zsh or another shell framework.

Useful navigation:

```text
Ctrl-R    fuzzy history search
Ctrl-T    fuzzy file insertion
Alt-C     fuzzy cd

z foo     zoxide ranked directory jump
zi        interactive zoxide selection
```

---

# Git and GitHub workflow

Responsibilities:

```text
Git
    source control

Lazygit
    repo-wide staging, commits, rebases, conflict work

LazyVim / Gitsigns / Snacks
    in-buffer hunks, blame, history, diff navigation

gh
    GitHub PRs, issues, checks, review, API
```

Shared Git defaults include:

- default branch `main`
- fetch pruning
- automatic upstream setup on first push
- rerere
- histogram diff algorithm
- Delta pager
- Neovim as editor
- conditional work identity includes

Typical GitHub CLI workflow:

```bash
gh pr status
gh pr list
gh pr create --fill
gh pr view
gh pr checks
gh pr checks --watch
gh pr checkout 123
gh pr review 123
```

Useful LazyVim Git mappings:

```text
<leader>gg    Lazygit

]h            next Git hunk
[h            previous Git hunk

<leader>ghp   preview hunk
<leader>ghs   stage hunk
<leader>ghr   reset hunk

<leader>gp    GitHub pull requests
<leader>gi    GitHub issues
<leader>gB    open current file/line on GitHub
<leader>gY    copy GitHub URL
```

Fugitive and Octo are intentionally not installed at present.

Multi-agent work (see "AI-assisted development toolchain" below), when
Treehouse is installed, uses isolated worktrees managed by `treehouse`
rather than your current branch/checkout. It does not change the shared Git
defaults above.

---

# Neovim / LazyVim

Neovim is installed through DNF.

The editor configuration uses:

```text
LazyVim
lazy.nvim
Mason
Treesitter
Conform
nvim-dap
```

`vim.pack` is intentionally not used because LazyVim is built around `lazy.nvim`.

## Navigation

```text
<leader>fp    projects
<leader>ff    files
<leader>/     grep
<leader>,     buffers
<leader>fr    recent files
<leader>e     explorer

Shift-h       previous buffer
Shift-l       next buffer
<leader>bb    previous/other buffer
<leader>bd    delete current buffer
<leader>bi    delete invisible buffers

Ctrl-h/j/k/l  move between windows
```

The project picker keeps existing buffers open. This is standard Neovim behavior and is intentionally left stock.

## Sessions

```text
<leader>qs    restore current-directory session
<leader>qS    select saved session
<leader>ql    restore last session
<leader>qd    do not save current session
```

## Code navigation

```text
gd            definition
gr            references
gI            implementation
gy            type definition
K             hover

<leader>ca    code action
<leader>cr    rename

Ctrl-o        jump backward
Ctrl-i        jump forward

]d / [d       diagnostic next/previous
]e / [e       error next/previous
]w / [w       warning next/previous

s             Flash jump
S             Treesitter-aware Flash jump
```

## Quitting

Use:

```text
<leader>qq
```

or:

```vim
:qa
```

Avoid using `:q` merely to move between files; `:q` closes a window.

---

# .NET development

The .NET setup separates language support, testing, and debugging.

```text
roslyn.nvim
    C# language intelligence

EasyDotnet
    solution/project awareness
    native MTP/xUnit test runner

nvim-dap
    generic debugger framework

Mason netcoredbg
    .NET debugger backend

mise
    .NET SDK/runtime
```

EasyDotnet's own LSP integration is disabled; `roslyn.nvim` owns LSP client
configuration and Mason owns the Roslyn binary. The mise-managed
`dotnet:EasyDotnet` global tool is the companion server required by the
`easy-dotnet.nvim` plugin; it does not replace Roslyn or `netcoredbg`.

## Testing

The tested setup uses:

- xUnit v3
- Microsoft Testing Platform
- EasyDotnet native test runner

C# buffers preserve LazyVim's test semantics:

```text
<leader>tr    Run Nearest
<leader>tt    Run File
<leader>td    Debug Nearest
```

Open the EasyDotnet test explorer with:

```vim
:Dotnet testrunner
```

It is configured as a right-side vertical split.

## Debugging

EasyDotnet owns the project-aware DAP registration, while Mason owns the
`netcoredbg` executable. The configured `bin_path` points EasyDotnet at Mason's
package, preventing EasyDotnet's companion server from downloading a second
debugger. Mason's generic `NetCoreDbg: Launch` configuration is suppressed so
only EasyDotnet appears in the C# debug picker. `nvim-dap` remains the generic
debugger framework.

Repository-specific `.vscode/launch.json` files are considered project configuration rather than workstation configuration.

## Formatting

C# formatting uses project-local CSharpier through Conform.

---

# Angular / TypeScript development

The frontend setup uses:

```text
VTSLS
Angular Language Server
ESLint Language Server
Conform
project-local Prettier
project-local ESLint/angular-eslint
```

From a repository with a committed `package.json`, use its scripts rather than
globally installed framework commands:

```bash
npm install
npm run build
npm start
npm test
npm run lint
npx prettier --check .
```

Open Neovim from the repository root after installing dependencies. Use
`:checkhealth vim.lsp` to confirm that VTSLS, Angular Language Server, and ESLint
are attached when the repository has a supported ESLint configuration. VTSLS
uses the repository's TypeScript SDK.

Prettier remains project-local:

```bash
npm install --save-dev prettier
```

ESLint remains project-local.

The editor-side `eslint-lsp` is Mason-managed. Its formatter is disabled so
ESLint provides diagnostics and code actions while project-local Prettier is
the only JavaScript, TypeScript, and Angular-template formatter.

ESLint handles diagnostics/code actions; Prettier owns formatting.

The split is intentional:

- mise owns the Node runtime
- each repository owns TypeScript, ESLint, angular-eslint, Prettier, and its
  test runner through `package.json`
- Mason owns VTSLS, Angular Language Server, the ESLint editor bridge, and the
  JavaScript debug adapter
- VTSLS is configured to use the workspace TypeScript SDK

JSON and YAML language servers remain Mason-owned. Their formatting falls back
to the language server unless a project-local Prettier executable is available.

## Debugging

The LazyVim TypeScript extra registers the Mason-owned `js-debug-adapter` for
Node, Chrome, and Chromium-compatible workflows. Project-specific launch
details belong in `.vscode/launch.json`; the workstation does not guess the
application URL or browser process.

The Angular smoke fixture contains an attach configuration that proves source
mapping without requiring a global Angular CLI. Modern Angular development
uses the `application` builder, but its esbuild source maps currently have an
[open breakpoint-binding bug in `vscode-js-debug`](https://github.com/microsoft/vscode-js-debug/issues/2304).
The fixture therefore keeps its normal build and serve workflow on the modern
builder and provides a debug-only webpack target until that upstream bug is
resolved. To exercise it manually:

```bash
cp -R tests/fixtures/angular-smoke /tmp/angular-smoke
cd /tmp/angular-smoke
npm install
npm run start:debug
```

In another terminal, start Chrome or Chromium with a disposable debug profile:

```bash
chromium \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/angular-debug-profile \
  http://localhost:4200
```

Open `/tmp/angular-smoke` in Neovim, set a breakpoint on
`this.answer.set(answer)` in `src/app/app.ts`, press `<leader>dc`, select
`Angular: Attach Chrome/Chromium`, and click **Calculate** in the browser. The
breakpoint should resolve against the emitted source map and stop on the
TypeScript line. Replace `chromium` with the installed Chrome/Chromium command
when necessary.

---

# Python development

The Python setup uses mise for the interpreter and `uv` command, while every
project owns its environment and development dependencies:

```bash
uv init --package
uv add --dev pytest ruff
uv sync
uv run python -m your_package
uv run pytest
uv run ruff check .
uv run ruff format --check .
uv build
```

`uv sync` creates a project-local `.venv`; it does not modify the mise-managed
Python installation. In Neovim, the LazyVim Python extra provides Pyright,
Ruff, pytest discovery through Neotest, virtual-environment selection with
`<leader>cv`, and debugging through `nvim-dap-python` plus Mason's `debugpy`.
Use `:checkhealth vim.lsp` to confirm Pyright and Ruff are attached to a Python
buffer.

Formatting and lint ownership is split deliberately:

- the project declares Ruff and all rules in `pyproject.toml`, so shell and CI
  use `uv run ruff ...`
- Mason's Ruff binary is editor-only and Conform uses it for format-on-save
- Mason owns Pyright and debugpy because they are editor adapters
- pytest and all application dependencies remain in the project

Repository-specific debug targets belong in `.vscode/launch.json`. To verify
the included module-launch example:

```bash
cp -R tests/fixtures/python-smoke /tmp/python-smoke
cd /tmp/python-smoke
uv sync --all-groups
nvim .
```

Set a breakpoint on `answer = left * right` in
`src/dotfiles_smoke/calculator.py`, press `<leader>dc`, and choose
`Python: Module`.
The debugger should stop inside the project interpreter without adding debugpy
to the project's dependencies.

---

# OCaml development

Install the profile explicitly:

```bash
./install.sh --ocaml
```

The default profile creates the named switch `dotfiles-ocaml-5.5.0`, selects it
as the global opam switch, and installs dune, utop, `ocaml-lsp-server`,
OCamlFormat, and Earlybird into that switch. The selection is recorded in the machine-local
file `~/.config/dotfiles/ocaml.conf`; it is not tracked by Git. The tracked Zsh
configuration sources opam's generated environment hook when it exists, so a
new shell exposes the selected switch without allowing `opam init` to edit
`.zshrc`.

To intentionally bootstrap a different stable compiler release:

```bash
OCAML_COMPILER_VERSION=5.4.1 ./install.sh --ocaml
```

The version becomes a separate named opam switch. Existing switches are not
deleted or overwritten.

## Project workflow

For a new project using the profile switch:

```bash
dune init proj hello
cd hello
opam install . --deps-only --with-test
dune build
dune exec hello
dune runtest
dune fmt
dune utop
nvim .
```

`dune init proj hello` is the easiest starting point for a new application: it
creates `dune-project` plus `bin`, `lib`, and `test` directories. To make its
executable debuggable with Earlybird, two changes are required.

First, ensure the executable stanza in `bin/dune` includes bytecode mode:

```lisp
(executable
 (name main)
 (modes byte exe))
```

Second, add `(map_workspace_root false)` to `dune-project`. Dune 3.0 and above
remaps build-tree paths in a way that prevents Earlybird from resolving
breakpoints back to source files; `dune init proj` does not add this line, so
it must be added by hand:

```lisp
(lang dune 3.14)

(map_workspace_root false)

(name hello)
```

Without this, breakpoints will silently never verify and the debug session
will run to completion without stopping, even though the build and launch
otherwise succeed. Note also that OCaml's bytecode debug info only attaches
to actual sub-expressions: a bare one-line `let () = print_endline "..."` (the
`dune init proj` default) has no breakpointable location on its single line.
Use a program with at least one real intermediate expression (for example a
`let` binding on its own line before the final call) if you want to test that
breakpoints are hit.

Use the executable name declared by the project's `dune` files with
`dune exec`. For an existing repository, begin with
`opam install . --deps-only --with-test`, then use its committed build, run,
and test aliases.

Projects that require a different compiler should create a local switch and
install the editor tools into that same switch:

```bash
opam switch create . 5.4.1
opam install . --deps-only --with-test
opam install dune utop ocaml-lsp-server ocamlformat
```

Because opam automatically selects a local switch from its directory, shell
commands and Neovim then use the project-specific compiler and packages.

## Neovim workflow

The LazyVim configuration becomes active only when the `opam` executable is
present. It adds the OCaml Treesitter parser and configures `ocamllsp` for
OCaml, interfaces, Dune files, Menhir, ocamllex, and Reason. The server starts
through `opam exec`, so it follows the switch selected for the project. Mason
is explicitly disabled for this server.

OCaml LSP provides diagnostics, completion, hover information, definitions,
references, rename, and code actions through the normal LazyVim mappings.
Formatting uses the OCamlFormat binary from the same switch through LSP; use
`<leader>cf` or the normal format-on-save behavior. Run Dune commands from a
LazyVim terminal (`<C-/>`) when an editor-adjacent build or test loop is useful.
Use `:checkhealth vim.lsp` in an OCaml buffer to confirm that `ocamllsp` is
attached.

## Debugging

The optional profile installs the opam-owned `earlybird` package. It provides
the `ocamlearlybird` Debug Adapter Protocol server, and the LazyVim DAP extra
is configured to launch it through the active opam switch. In an OCaml buffer:

1. Set a breakpoint with `<leader>db` (`:DapToggleBreakpoint`).
2. Press `<leader>dc` (`:DapContinue`) and choose
   `OCaml: build and debug Dune executable`.
3. Select the relevant `.bc` target when the project exposes more than one.
   The most recently selected target is offered first for reuse during the
   Neovim session.
4. LazyVim asks Dune to build that exact target and launches Earlybird only
   after the build succeeds.

Target discovery uses Dune's rule description rather than assuming an
`_build/default` layout, so alternate Dune build contexts resolve to the
artifact path reported by Dune. A failed build is shown as an editor error and
the DAP session is not started. Projects with generated or otherwise unusual
layouts can choose `OCaml: debug bytecode executable (manual)` and pick an
existing `.bc` artifact directly.

The adapter supports normal launch, breakpoints, stepping, stack inspection,
and variables through `nvim-dap`. It is restricted to bytecode executables;
native binaries are not supported. It is also a launch configuration, not a
general attach-to-an-already-running-native-process workflow. Earlybird has
known limitations around Dune's workspace-root handling (see
[Project workflow](#project-workflow) for the required `dune-project`
setting); `OCaml: build and debug Dune executable` checks for
`(map_workspace_root false)` before launching and aborts with an explicit
error if it is missing, rather than starting a session that can never stop at
a breakpoint. The repository's smoke fixture exercises the required bytecode
build shape; the interactive breakpoint itself must be checked in Neovim
because it depends on the editor session.

---

# Disposable development workflow validation

The repository includes network-dependent fixtures that exercise real project
tooling in temporary directories:

```bash
./scripts/test-dev-workflows.sh
./scripts/test-dev-workflows.sh --dotnet
./scripts/test-dev-workflows.sh --angular
./scripts/test-dev-workflows.sh --python
./scripts/test-dev-workflows.sh --ocaml
./scripts/test-dev-workflows.sh --latex
```

The .NET check creates a disposable console and xUnit project, then restores,
builds, tests, and runs them.
The Angular check installs only fixture-local dependencies, formats, lints,
tests, exercises both the modern and debug builds with source maps, starts the
debug server, and probes it.
The Python check resolves an isolated environment, runs the package and tests,
lints, checks formatting, and builds both source and wheel distributions. The
OCaml check resolves the fixture through opam and exercises Dune build, run,
test, format, and bytecode targets using the configured profile switch. The
LaTeX check formats and builds a multi-file document, resolves a BibLaTeX
citation through Biber, verifies its PDF, and checks a deliberate compile
error. These larger checks are intentionally separate from `scripts/test.sh`;
the normal repository suite validates their configuration without fetching
language ecosystems.

---

# Markdown

Markdown authoring is part of the default shared LazyVim profile. LazyVim owns
the Markdown extra and its plugins; Mason owns the editor-facing Marksman
binary. A repository's Prettier, Markdown linter and table-of-contents tooling
remain project-local.

LazyVim core already provides the `markdown` and `markdown_inline` Tree-sitter
parsers, including injected highlighting for installed fenced-code languages,
plus wrapped, spellchecked Markdown buffers. The Markdown extra adds GFM-aware
rendering, link intelligence, link/document diagnostics and browser preview.
Catppuccin colours the in-editor rendered headings, code blocks, links and
tables.

The extra's global markdownlint-cli2 and markdown-toc integrations are
deliberately disabled. Their default style policy is too noisy for a common
profile and can overlap project formatting. Projects that require them should
declare and configure them locally; Conform already uses a project's local
Prettier when it is available.

Useful Markdown bindings:

```text
gd            follow an internal file or heading link through Marksman
Ctrl-o        return after following a link
gx            open the URL under the cursor
<leader>cp    toggle the live browser preview
<leader>um    toggle rendered Markdown inside Neovim

<leader>mt    insert a GFM table
Alt-l / Alt-h move to the next/previous table cell
<leader>mr    insert a table row below
<leader>mc    insert a table column to the right
```

The remaining row and column operations are discoverable under `<leader>m`
through WhichKey. Tables are real Markdown source and are aligned on leaving
insert mode; the browser preview remains the final check for GitHub rendering.

On Fedora and Parrot, the preview opens through the distro-owned `xdg-open`.
On Fedora WSL, the platform adapter routes both `gx` and preview URLs through
the existing `wsl-open` helper to the Windows browser even though Windows PATH
inheritance is disabled. macOS can use the preview plugin's native `open`
support without a common-config change.

---

# LaTeX

LaTeX support is optional:

```bash
# Native Fedora
./install.sh --latex

# Fedora WSL
./install.sh --platform fedora-wsl --latex
```

or:

```bash
./scripts/install-latex.sh
```

Fedora owns the TeX distribution and Biber.

Mason owns `texlab`.

LazyVim owns the VimTeX editor plugin. TeX project build configuration remains
in the project.

The optional component explicitly installs `latexmk`, `latexindent`, BibLaTeX,
and Biber alongside the medium TeX Live scheme. It does not install any LaTeX
binaries when `--latex` is omitted.

## LaTeX editing workflow

Open either the main file or an included `.tex` file in LazyVim. VimTeX owns
project discovery, compilation, PDF viewing, and parsed build errors; TexLab
owns completion, navigation, document symbols, diagnostics, and formatting.
TexLab's build-on-save and ChkTeX integrations are disabled so they do not
duplicate VimTeX's build log or introduce a second diagnostic stream.

The high-value bindings below use LazyVim's local leader, `\`. They are also
shown by which-key after pressing `\l`.

| Binding | Command | Purpose |
| --- | --- | --- |
| `\ll` | `:VimtexCompile` | Start or stop continuous `latexmk` compilation |
| `\lv` | `:VimtexView` | Open the PDF and forward-search to the cursor |
| `\le` | `:VimtexErrors` | Toggle parsed LaTeX/Biber errors in quickfix |
| `\lo` | `:VimtexCompileOutput` | Inspect raw compiler output |
| `\lt` | `:VimtexTocOpen` | Open navigable document structure |
| `\li` | `:VimtexInfo` | Show the detected main file, compiler, and viewer |
| `<leader>cf` | LazyVim format | Format through TexLab and Fedora's `latexindent` |

`\ll` starts VimTeX's default continuous `latexmk` mode. Save any related
source or bibliography file to rebuild; press `\ll` again to stop it.
Warnings remain available through `\le`, but only errors open quickfix
automatically. Use `]q` and `[q` to move between quickfix entries without
leaving Neovim.

TexLab supplies completion and go-to-definition for commands, labels,
references, and citations. LazyVim's normal LSP bindings apply, including
`gd`, `gr`, and `<leader>ss` for document symbols. Its formatter calls the
DNF-owned `latexindent`; a repository's `.latexindent.yaml` is discovered by
`latexindent --local` and remains project-owned. LazyVim's format-on-save
setting applies, with `<leader>cf` available for an explicit format.

`latexmk` detects BibLaTeX and runs Biber as required. A normal bibliography
setup therefore only needs project-local configuration such as:

```tex
\usepackage[backend=biber]{biblatex}
\addbibresource{references.bib}
```

VimTeX usually finds a multi-file document's main file by following
`\input`/`\include`. For an unambiguous project, add this near the top of
each included file:

```tex
% !TeX root = ../main.tex
```

An empty `main.tex.latexmain` marker or a project `.latexmkrc` containing
`@default_files = ('main.tex');` are supported alternatives. Run `\li` to
confirm which root VimTeX selected after opening a file.

On the Fedora KDE baseline, `\lv` uses the already-installed Okular and
supports forward SyncTeX. For inverse SyncTeX, set **Settings > Configure
Okular > Editor > Custom Text Editor** to:

```text
nvim --headless -c "VimtexInverseSearch %l '%f'"
```

Then Shift-click the PDF in Okular's browse mode. VimTeX is deliberately
loaded at startup so this callback can locate the correct running Neovim
instance. If Okular is unavailable (for example, on a non-KDE installation),
`\lv` uses `xdg-open`; PDF viewing still works through the desktop default,
but viewer-specific forward/inverse SyncTeX is not promised. The LaTeX option
does not install another PDF application for that fallback case.

On Fedora WSL, `--latex` installs the same DNF-owned toolchain but does not add
a Linux desktop PDF application. Its platform-specific Neovim adapter
overrides VimTeX's viewer with `wsl-open`, so `\lv` opens the generated PDF in
its Windows handler without putting Windows launch logic in the shared editor
configuration. That Windows-handler fallback does not currently provide
forward or inverse SyncTeX. Verify the optional WSL toolchain separately with
`platforms/fedora-wsl/scripts/verify.sh --latex`; combining `--latex` with the
installer's `--smoke-test` also runs the disposable multi-file build below.

The LazyVim TeX extra installs the LaTeX and BibTeX Tree-sitter parsers. It
intentionally leaves LaTeX highlighting to VimTeX's more complete syntax
engine, while BibTeX uses Tree-sitter. Both use the active Catppuccin palette,
as do LazyVim diagnostics, completion, symbols, and quickfix UI.

For discovery and troubleshooting, use `\li`, `:checkhealth vimtex`,
`:LspInfo`, `:ConformInfo`, or `:Mason`. The repeatable machine-level smoke
test is:

```bash
./scripts/test-dev-workflows.sh --latex
```

It formats and builds a disposable multi-file document, resolves a BibLaTeX
citation through Biber, verifies the PDF, then introduces a deliberate compile
error and checks that the log contains a quickfix-compatible file and line.

Mermaid CLI (`mmdc`) is installed through mise/npm.

Perl and Ruby are not separately managed through mise merely because TeX utilities use them.

---

# Verification

Run:

```bash
./scripts/verify.sh
```

The verifier checks:

- Fedora security baseline: SELinux enforcing, firewalld active, Secure Boot
  state (always, independent of `--hardening`)
- required core commands
- Stow-managed links
- machine-local theme state
- required theme assets
- derived Ghostty/Delta/tmux theme overrides
- Git local configuration
- mise configuration and commands
- expected Mason editor tooling and warnings for untracked Mason packages
- Neovim startup/version
- optional opam switch, compiler, and OCaml Platform tools
- Catppuccin tmux installation/version
- optional ASUS hardware profile, drivers, services, and Secure Boot state
- optional Fedora VM-host backend, KVM, libvirt, network, and storage validation
- optional Fedora VM-guest detection, agents, channels, and network route
- optional Fedora security-hardening profile settings (see "Optional Fedora
  security-hardening profile" above)
- optional AI-assisted development profile: Claude Code/Codex/Herdr/GNHF/
  backpass PATH ownership, FirstMate's clone, and Treehouse/No Mistakes
  (see "AI-assisted development toolchain" above) — and confirms none of
  it is present when the profile
  was not selected
- nested Git repositories
- obvious generated junk files

Missing essential components are failures. Optional/editor-specific omissions may be warnings.

Validate every tracked shell script and sourced shell fragment with Bash and
ShellCheck:

```bash
./scripts/lint.sh
```

The lint command supplies the Bash dialect for source-only fragments and
resolves sourced libraries relative to each script. It requires `shellcheck`
to be available in `PATH`.

Before opening a pull request, run the same read-only validation used by CI:

```bash
./scripts/lint.sh
./scripts/test.sh
git diff --check
```

The bootstrap harness covers Secure Boot helpers, power-profile service
handling, installer option validation and dry-runs, fresh and repeated local
setup, legacy Git identity migration, developer-tool ownership invariants, and
preservation of unrelated user files and symlinks. It validates the optional
OCaml profile's idempotency, switch state, and manager boundaries without
downloading a compiler. It also exercises GA402XZ and GA402RK hardware
preflights, fail-before-mutation behavior, and
representative package and service flows through command mocks.
The guest harness additionally proves that bare metal and unsupported
hypervisors fail before package mutation, no ASUS/NVIDIA, power, bridge, or
NetworkManager command is issued, and repeated guest setup preserves stable
local state.
The macOS harness validates the root-platform route, dry-run options, Homebrew
versus mise ownership, AeroSpace/Sway-equivalent bindings, the wrapped 3×3
workspace helper, reversible defaults, the macOS-native VimTeX PDF-viewer
override, and the absence of yabai/skhd.

Every integration-style test uses temporary home, XDG, OS-release, and DMI
state. Package managers, firmware tooling, and service commands are either
blocked or mocked, so the harness never installs packages, enrolls keys,
changes real services, or writes to the user's configuration.

GitHub Actions runs the full repository suite in a Fedora 44 container and the
focused macOS profile/lint checks on a macOS 26 arm64 runner for every pull
request and every push to `main`; Windows helpers run on a Windows runner. The
workflows install validation dependencies in their ephemeral environments, but
never perform a workstation install or change firmware, Secure Boot, MOK
enrollment, GPU/MUX settings, macOS preferences, services, or battery limits.

---

# Updating Starship themes

Edit only:

```text
starship/.config/starship/template.toml
```

Then regenerate:

```bash
./scripts/update-starship-themes.sh
```

The generated flavor configs are also tracked so a clone can be used without running generation first.

---

# Repository hygiene

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

---

# Troubleshooting

## `sudo`, `git`, or other `/usr/bin` commands suddenly disappear

In Zsh, `path` is a special array tied directly to `PATH`.

Do **not** use `path` as a casual variable:

```zsh
# Bad
path="$(command -v something)"
```

Use:

```zsh
cmd_path="$(command -v something)"
```

## Theme switching does not affect an existing shell

Run:

```bash
exec zsh
```

The `theme` Zsh wrapper normally does this automatically.

## Neovim does not update immediately after a theme switch

Refocus the Neovim window. The Catppuccin config checks the machine-local theme on `FocusGained`.

## EasyDotnet warns that its Roslyn LSP is disabled

Expected. Roslyn is owned by `roslyn.nvim`.

## EasyDotnet warns about `dotnet ef`

A repository-local `dotnet-ef` tool is preferred when the project requires it.

## `mise` fails to install `dotnet:EasyDotnet` with a missing ICU error

```text
Couldn't find a valid ICU package installed on the system. Please install
libicu (or icu-libs) using your package manager and try again.
```

The .NET runtime needs ICU for globalization support, and `libicu` is part
of this repository's base Fedora/DNF package list precisely so this
doesn't happen — if you see this, the install ran before `libicu` was
added, or `libicu` failed to install for some other reason. Install it and
rerun:

```bash
sudo dnf install -y libicu
mise install
```

## Ghostty cannot find packaged themes on Fedora/Terra

The Terra Ghostty RPM may omit the upstream bundled theme collection.

This repository tracks the four required Catppuccin Ghostty theme files directly.

## Ghostty starts Bash after the installer configured Zsh

Confirm that the account entry changed:

```bash
getent passwd "$(id -un)" | cut -d: -f7
```

If this reports `/usr/bin/zsh` or `/bin/zsh` while `echo "$SHELL"` still reports
Bash, reboot the machine. The already-running Plasma, systemd user, and D-Bus
session can retain `SHELL=/bin/bash`, which Ghostty checks before the account
entry. `env -u SHELL ghostty --gtk-single-instance=false` is a useful diagnostic
because it makes an independent Ghostty process fall back to the passwd entry;
it is not required after rebooting.

## `pynvim` is not an executable

Expected. Verify the Python provider through Neovim health checks instead.

## `claude`/`codex`/`herdr` are not found after `--ai`

Confirm the AI profile's untracked mise config exists and mise sees it, then
reinstall:

```bash
cat ~/.config/mise/conf.d/ai.toml
mise install
```

If the file is missing, rerun `./scripts/install-ai.sh` (add `--codex`
and/or `--firstmate` as needed) — it is safe to rerun.

## `verify-ai.sh` reports a possible duplicate install

It found the command on `PATH` at a location mise does not report managing —
typically a native installer, Homebrew, or a global `npm install -g` of the
same tool installed outside this profile. Remove the other installation (see
each tool's own uninstall instructions) so only the mise-managed copy remains
on `PATH`.

## `treehouse` commands fail or a worktree seems stuck

Treehouse is not documented in detail here — see its own
[README](https://github.com/kunchenguid/treehouse) and `treehouse --help` for
the current command set (`get`/`enter`/`status`/`return`/`prune`/`destroy`/
`lease`) rather than relying on this document, which does not duplicate
fast-moving upstream option lists.

---

# Manual post-install checklist

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
   ./scripts/verify.sh
   ```

   When a hardware profile is configured, this automatically includes its
   driver, service, DMI, and Secure Boot checks. For a focused rerun, use
   `./scripts/verify-asus-hardware.sh`.

9. Confirm Git identity:

   ```bash
   git config --show-origin --get user.name
   git config --show-origin --get user.email
   ```

10. If the optional AI profile (`--ai`) was selected, authenticate each
    installed tool interactively: run `claude` (and `codex`, if installed)
    and follow its login prompt; FirstMate uses the `gh auth login` from
    step 5. See "AI-assisted development toolchain" above.

11. Confirm GitHub SSH:

   ```bash
   ssh -T git@github.com
   ```

12. Confirm the selected theme:

    ```bash
    cat ~/.config/dotfiles/theme
    ```

---

# Current defaults

```text
Distribution:         Fedora
Desktop:              KDE Plasma / Wayland
Optional session:     Sway / Wayland (`--sway`)
Terminal:             Ghostty
Shell:                Zsh
Prompt:               Starship
Terminal persistence: tmux
Editor:               Neovim + LazyVim
Git TUI:              Lazygit
GitHub CLI:           gh
Runtime manager:      mise
Optional OCaml:       opam (`--ocaml`)
Optional hardening:   conservative security profile (`--hardening`)
Optional AI profile:  Claude Code + Herdr, Codex/FirstMate optional (`--ai`)
Theme:                Catppuccin Macchiato
Accent:               Mauve
KDE decoration:       Classic
```

The goal is not to turn the workstation into a custom framework. The goal is a reproducible setup that remains understandable to someone already familiar with Fedora, Zsh, Neovim, Git, and the upstream tools themselves.
