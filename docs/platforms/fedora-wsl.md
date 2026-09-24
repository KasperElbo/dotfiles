# Fedora on WSL

The WSL variant treats Noctty (or another Windows terminal) and the Windows
desktop as the host UI. Fedora owns the shell and all development commands. It
composes the same Zsh, Git, Neovim/LazyVim, tmux, mise, Starship, fzf, Lazygit
and language configuration used by the normal Fedora workstation.

## Windows-side prerequisites

### WSL package version

**Minimum proven-supported WSL version: 2.7.13.** This is the oldest version
on which the repository's complete Fedora WSL flow has been validated,
including its current bootstrap, systemd assumptions, `/etc/wsl.conf` interop
policy, and explicit Windows executable invocation. Older WSL versions may
work, but they are unvalidated and are not part of the currently tested and
supported baseline. This support floor records the proven integration; it is
not evidence that a specific WSL bug was fixed in exactly 2.7.13.

Check the Store-delivered WSL package version from Windows PowerShell before
starting:

```powershell
wsl --version
```

If it is older than 2.7.13, update the WSL package and check again. Updating
Windows itself is not normally required when the package update succeeds:

```powershell
wsl --update
wsl --version
```

### DNS, VPN and networking

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
offered under `--platform fedora-wsl` at all. See
[Fedora WSL policy](../profiles/tailscale.md#fedora-wsl-policy) for the
host-vs-WSL-node comparison and why Windows-host-only Tailscale is the
recommended architecture here.

### Windows bootstrap

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
Noctty for the current user through its official Scoop bucket. If Scoop
itself is not already installed, the script first bootstraps it with Scoop's
official installer, fetched at a pinned commit and checked against its pinned
SHA-256 before it runs, before adding the Noctty bucket. It is safe to
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

# Additionally install the optional Handy voice-dictation application.
.\platforms\windows\install.ps1 -Handy
```

`-Handy` is the only optional desktop tooling this script installs. It is
opt-in, per-user and Scoop-owned like Noctty, and it changes nothing about the
WSL or terminal bootstrap. See the
[optional dictation profile](../profiles/dictation.md#windows) for the
shortcut, the first-run steps, where models and transcript history are kept,
and how to verify and uninstall it.

If Noctty already has a user-managed `command =` setting, the script retains
it and omits the managed Fedora command. Otherwise the marked block in
`%LOCALAPPDATA%\noctty\config.ghostty` starts the selected Fedora distribution.
User-authored Noctty settings remain below the block and therefore stay
separate from the shared Ghostty source. Noctty is still a young project, so
keep another working Windows terminal available while evaluating it.

After the Windows bootstrap completes, run the read-only installed-state
verifier from the repository root:

```powershell
.\verify.ps1
```

It reads `%LOCALAPPDATA%\dotfiles\windows-selection.json` and reports pass,
warning, and fail outcomes. A failed repository-owned invariant returns a
nonzero exit code. When Noctty was selected, verification requires its bucket,
package, current executable, and resolved command to remain Scoop-owned, and
selected Handy is held to the same Scoop ownership through the `extras`
bucket. It
also compares every managed Noctty copy to the current checkout and detects
broken or stale checkout links. The WSL check is limited to Windows ownership:
the proven WSL package version and the recorded Fedora distribution on WSL 2.
It does not launch the distribution, inspect Linux packages, update Scoop or
WSL, write configuration, or authenticate any service.

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
repository from inside Fedora. The distro needs nothing else from you: a clean
Fedora WSL image has no Gawk, and the installer's first act is to install it,
and any other package it runs before its own package step, with `sudo dnf`
(see [Troubleshooting](../troubleshooting.md#the-installer-first-installs-gawk-or-another-base-package)).
Git is installed here only because the clone needs it first:

```bash
sudo dnf upgrade --refresh
sudo dnf install -y git
mkdir -p ~/src
git clone <REPOSITORY_URL> ~/src/dotfiles
cd ~/src/dotfiles
./install.sh --platform fedora-wsl --dry-run
./install.sh --platform fedora-wsl
```

The installer makes Zsh the user's default login shell. An already-running
Noctty/WSL process remains the Bash process that started before that account
change; changing the passwd entry cannot replace it retroactively. Open a new
Noctty/WSL session to enter Zsh normally (no Windows reboot is required), or
run `exec zsh -l` to replace the current shell immediately. Installation and
verification do not depend on doing either: bootstrap scripts establish the
mise shim and user-bin environment explicitly.

Keep repositories under the WSL Linux filesystem, normally `~/src`. `/mnt/c`
is useful for exchanging files with Windows, but its metadata, file-watching,
case-sensitivity and I/O behavior make it a poor default for Git repositories,
Node dependency trees and build output.

## PATH and Windows interoperability

Windows commonly appends its PATH to a WSL process. That inherited PATH adds
noise and makes explicitly named Windows commands such as `node.exe`,
`dotnet.exe`, `python.exe`, `claude.exe`, or `codex.exe` available from Linux.
Ordinary extensionless Linux lookup does not normally treat `codex.exe` as a
candidate for `codex`, so the mere presence of a same-base `.exe` does not
shadow an extensionless Linux command. The WSL platform hook removes
`/mnt/<drive>/...` entries before `.zshrc` executes any tools. mise then
activates only the Linux-native runtimes installed inside Fedora.

This profile treats "no Windows directories in `PATH`" and "explicit Windows
executables still run" as two independent properties, each
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
| `wsl-open URL_OR_PATH [...]` | Open one or more URLs, files, or directories with their Windows handlers |

`wsl-open` passes `http`, `https`, `ftp`, `ftps`, `mailto`, and `file` URIs
through unchanged. Every other argument must name an existing Linux file or
directory. Relative paths are resolved and each path is converted with
`wslpath -w` before Explorer is invoked, so spaces, Unicode, and argument
boundaries survive the WSL-to-Windows transition. A nonexistent path or an
unsupported URI scheme is an error; unknown strings are never guessed to be
URLs.

`BROWSER=wsl-open` lets Linux-native tools such as `gh auth login --web` open
the Windows browser. Set `WINDOWS_SYSTEM_ROOT` only if Windows is not available
at the conventional `/mnt/c/Windows` mount. Neovim's `"+` and `"*` registers
use the same clipboard helpers through a WSL-only LazyVim plugin spec.

`verify.sh` checks the two properties separately, and is explicit about which
evidence proves which.

"no Windows directory in `PATH`" is proved by reading `/etc/wsl.conf` itself
and asserting `[interop] appendWindowsPath=false` — with the same
`render_ini_section_keys` that `configure-interop.sh` writes the file with, so
there is one parser, not two. That setting, not the Zsh hook, is what governs
every context that is not an interactive Zsh login shell: systemd units,
`wsl.exe -e`, VS Code's integrated shell, cron. Alongside it the verifier
samples an **unsanitized** `PATH` (`zsh -f`, no rc files, so the stripper in
`platform-env.zsh` cannot mask an entry that is really there) and fails naming
any Windows entry in it; the `.exe` absence lookups run against that same
sample. The sanitized login `PATH` is still checked, and is still reported —
but only as proof that the Zsh layer works. It cannot be evidence that Windows
`PATH` injection is off, because it is the stripper's own output: a machine
where `/etc/wsl.conf` was written but `wsl --shutdown` never ran shows a
perfectly clean login `PATH` while every non-interactive context inherits the
Windows one.

"explicit Windows executables still run" is proved behaviorally: a dedicated
check actually runs `/mnt/c/Windows/System32/cmd.exe /c echo interop-ok`
and confirms it prints
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

`--containers` reuses the [native Fedora profile](../profiles/containers.md)
and is supported on Fedora WSL, with WSL-specific preconditions checked explicitly
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
bind-mount relabeling documented in the
[containers profile](../profiles/containers.md#selinux-volume-labels).
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

Identical rootless-user-socket behavior to native Fedora (see
[Rootless API socket](../profiles/containers.md#rootless-api-socket-docker-compatible-tooling)): `--containers-api-socket` enables `podman.socket` in your
own systemd `--user` instance only, socket-activated, never bound to TCP.
`DOCKER_HOST` is only relevant to a Docker-CLI-compatible client running
*inside this same WSL instance*; there is no bridging to a Windows-side
Docker client or named pipe, and none is planned — a Windows-side consumer
that needs a Docker-compatible endpoint is out of scope for this profile,
consistent with not installing Docker Engine or Docker Desktop inside WSL as
a parallel runtime.

### Compose and everyday commands

Unchanged from native Fedora: `podman compose`, the SELinux-label table, the
common command list, and the `depends_on` hang caveat in the
[containers profile](../profiles/containers.md) all apply identically inside
WSL.

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

## Validation

The normal installer verifies `command -v` ownership and starts representative
`.NET`, Node/npm/npx, Python/uv and optional OCaml commands. For disposable,
network-dependent project tests covering .NET, Angular/TypeScript, Python,
JSON and the installed OCaml profile, run:

```bash
./install.sh --platform fedora-wsl --dev-workflows
```

`--smoke-test` is the deprecated spelling of `--dev-workflows`; it still
resolves to identical behaviour and warns.

The optional AI profile (`--ai`, `--codex`, `--firstmate`, `--gnhf` and
`--backpass`; see [the AI profile guide](../profiles/ai.md)) is portable CLI
tooling with no GUI or hardware dependency, so it is fully supported here. The
early PATH policy ensures the Linux-native, mise-managed installation always
takes precedence over any Windows executable of the same name.
