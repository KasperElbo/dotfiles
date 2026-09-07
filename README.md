# Development and Security-Lab Dotfiles

Opinionated, reproducible dotfiles for a keyboard-driven development workstation built around:

- Fedora
- Fedora on WSL, with Windows as the desktop and terminal host
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

1. **Use the native package manager for machine-level tools.** Fedora/DNF or
   Parrot/APT owns operating-system and integrated tools.
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
--platform PLATFORM fedora (default) | fedora-wsl | parrot-ctf

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

--hardware MODEL   install ASUS hardware support for ga402xz or ga402rk
                   default: disabled
--secure-boot      require Secure Boot for the selected hardware profile
--charge-limit N   set ASUS battery charge limit (40-100 percent)

--dry-run          print the installation plan only
--non-interactive  use defaults without prompting

-h, --help         show help
```

The Fedora WSL installer intentionally exposes only `--theme`, `--ocaml`,
`--smoke-test`, `--dry-run`, and `--non-interactive`. Fedora desktop, LaTeX,
Sway, VM and hardware flags are rejected rather than silently ignored.

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

For the strongest process-wide policy, merge this into `/etc/wsl.conf`
manually; do not replace unrelated existing sections:

```ini
[interop]
appendWindowsPath=false
```

Restart WSL from PowerShell after changing it:

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

Do not enable it merely to satisfy this dotfiles profile.

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

If the Windows 1Password SSH Agent is preferred, enable its WSL integration in
1Password and use Windows OpenSSH explicitly rather than restoring the Windows
PATH. Test it with:

```bash
/mnt/c/Windows/System32/OpenSSH/ssh.exe -T git@github.com
```

Then add the following machine-local setting to `~/.config/git/local`:

```gitconfig
[core]
    sshCommand = /mnt/c/Windows/System32/OpenSSH/ssh.exe
```

Any 1Password commit-signing snippet also belongs in that local file. This is
an explicit boundary choice: otherwise Git and SSH remain entirely inside
Fedora.

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

## Validation

The normal installer verifies `command -v` ownership and starts representative
`.NET`, Node/npm/npx, Python/uv and optional OCaml commands. For disposable,
network-dependent project tests covering .NET, Angular/TypeScript, Python and
the installed OCaml profile, run:

```bash
./install.sh --platform fedora-wsl --smoke-test
```

The WSL profile does not install AI tooling. A future optional AI profile can
compose with it; the early PATH policy ensures a Linux-native installation
takes precedence over any Windows executable.

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

This preserves only the desktop wallpaper. The Sway lock-screen wallpaper
continues to follow the selected Catppuccin flavour.

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

---

# Installation architecture

The repository has three ownership layers:

| Layer | Owns | Must not own |
|---|---|---|
| Portable common | Shared Stow packages, user-local Git/theme state, mise tools, opam switch/tool setup, and the tmux theme | Native package-manager installation, services, hardware, desktop integration, or OS-specific paths |
| `platforms/fedora` | DNF/Terra packages, including the opam binary and OCaml build prerequisites; KDE and Sway integration; system services; SELinux/system paths; Secure Boot; and ASUS hardware | Copies of shared Zsh/Git/Neovim/tmux/mise configuration or OCaml packages inside opam switches |
| `platforms/fedora-wsl` | WSL detection, CLI prerequisites, early Windows PATH isolation, explicit clipboard/browser interop and WSL verification | Fedora desktop, Ghostty, hardware, GPU, VM host/guest, invasive host networking changes, credentials or copies of portable configuration |
| `platforms/parrot-ctf` | Parrot/APT prerequisites, KVM/SPICE guest agents, Debian command shims, a narrow uv-only mise manifest, and lab-boundary verification | Fedora/Terra/KDE/ASUS provisioning, host virtualization, credentials, shared folders, or a duplicate Parrot security-tool catalogue |

The shared Stow package directories remain at the repository root to preserve
existing symlink targets. `common/stow.sh` is their authoritative package
manifest and deployment entry point. Each platform installer calls the common
scripts directly and then adds only its own integration layer.
`common/stow.sh --headless` omits the Linux GUI terminal package for the WSL
composition without changing the normal Fedora manifest.
`common/stow.sh --headless --without-mise` lets the Parrot profile substitute
its narrow lab manifest without inheriting general-workstation runtimes.

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
    ├── common/install-ocaml.sh                            optional switch/tools
    ├── common/install-tmux-theme.sh
    ├── platforms/fedora/scripts/install-kde-theme.sh      optional
    ├── platforms/fedora/scripts/install-latex.sh          optional
    ├── platforms/fedora/scripts/install-vm-host.sh        optional
    ├── platforms/fedora/scripts/install-vm-guest.sh       optional, guest only
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


---

# Package ownership

Avoid installing the same tool through multiple package managers.

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
neovim
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

## Terra RPM repository

The reference setup uses Terra packages for:

```text
ghostty
mise
starship
```

These remain RPM-owned. mise itself is **not** installed by mise.

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
inventory, derived from the tracked LazyVim extras and local plugin specs:

| Mason package | Declared by | Responsibility |
|---|---|---|
| `angular-language-server` | LazyVim Angular extra | Angular template and framework language support |
| `debugpy` | LazyVim Python extra | Python debug adapter used by `nvim-dap-python` |
| `eslint-lsp` | LazyVim ESLint extra | Editor-to-project ESLint bridge |
| `js-debug-adapter` | LazyVim TypeScript extra when DAP is enabled | JavaScript and TypeScript debugging |
| `json-lsp` | LazyVim JSON extra | JSON language support |
| `lua-language-server` | LazyVim core | Lua language support for Neovim configuration |
| `netcoredbg` | `lua/plugins/dotnet.lua` | Debug adapter binary used by EasyDotnet |
| `pyright` | LazyVim Python extra | Python language server and type checking |
| `roslyn` | `lua/plugins/dotnet.lua` | C# language server used by `roslyn.nvim` |
| `ruff` | LazyVim Python extra | Editor diagnostics and formatting using project configuration |
| `shfmt` | LazyVim core | Editor formatting for shell files |
| `stylua` | LazyVim core | Editor formatting for Lua files |
| `texlab` | LazyVim TeX extra | TeX language support |
| `vtsls` | LazyVim TypeScript extra, imported by Angular | TypeScript language server using the workspace TypeScript SDK |
| `yaml-language-server` | LazyVim YAML extra | YAML language support |

`scripts/verify.sh` checks this expected inventory and warns about additional
Mason packages so stale or manually installed tools can be reviewed instead of
silently acquiring a second owner.

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
Waybar, Fuzzel, Mako, swaylock, and the flavour-matched wallpaper. A running
Sway session is reloaded automatically; new Fuzzel invocations read the new
generated configuration. Ghostty is reloaded through its systemd user service
when active, or directly with Ghostty's `SIGUSR2` reload signal when launched
from Sway.

Pass `--preserve-wallpaper` to keep the current KDE or Sway desktop wallpaper
while applying those theme changes. Swaylock remains flavour-controlled.

The four tracked 3840x2160 wallpapers form a flavour-matched tropical-island
day-to-night cycle adapted from the MIT-licensed Catppuccin wallpaper
collection. They are shared Fedora desktop theme assets used by both KDE and
Sway. Swaylock uses a separately tracked blurred and darkened derivative of the
active wallpaper. The exact upstream revision and license are recorded beside
the assets and in `LICENSES/Catppuccin.txt`.

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
| `Super+N` / `Super+Shift+N` | Dismiss / restore a Mako notification |
| `Super+Shift+V` | Open clipboard history |
| ASUS screenshot key / `Print` | Select and annotate a screenshot region |
| `Shift+Print` | Save the current output to `~/Pictures/Screenshots` |

Waybar remains visible and shows workspaces, the focused title, a compact system
tray, power profile, network, Bluetooth, audio, battery, and clock. Clicking
network, Bluetooth, or audio opens `nm-connection-editor`, `blueman-manager`,
or `pavucontrol`. Notifications use Mako. The Xwayland Video Bridge remains
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

1. Build a bytecode executable with `dune build`.
2. Set a breakpoint with `:DapToggleBreakpoint`.
3. Start the `OCaml: debug bytecode executable` configuration with
   `:DapContinue`.
4. Select the resulting `_build/default/.../*.bc` executable when prompted.

The adapter supports normal launch, breakpoints, stepping, stack inspection,
and variables through `nvim-dap`. It is restricted to bytecode executables;
native binaries are not supported. It is also a launch configuration, not a
general attach-to-an-already-running-native-process workflow. Earlybird has
known limitations, including Dune workspace-root handling, so projects should
use Dune 3.7 or newer and include `(map_workspace_root false)` when source
breakpoints do not resolve correctly. The repository's smoke fixture exercises
the required bytecode build shape; the interactive breakpoint itself must be
checked in Neovim because it depends on the editor session.

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
```

The .NET check creates, restores, builds and runs a disposable console project.
The Angular check installs only fixture-local dependencies, formats, lints,
tests, exercises both the modern and debug builds with source maps, starts the
debug server, and probes it.
The Python check resolves an isolated environment, runs the package and tests,
lints, checks formatting, and builds both source and wheel distributions. The
OCaml check resolves the fixture through opam and exercises Dune build, run,
test, format, and bytecode targets using the configured profile switch. These larger
download-based checks are intentionally separate from `scripts/test.sh`; the
normal repository suite validates their configuration without fetching
language ecosystems.

---

# LaTeX

LaTeX support is optional:

```bash
./install.sh --latex
```

or:

```bash
./scripts/install-latex.sh
```

Fedora owns the TeX distribution and Biber.

Mason owns `texlab`.

LazyVim owns the VimTeX editor plugin. TeX project build configuration remains
in the project.

Mermaid CLI (`mmdc`) is installed through mise/npm.

Perl and Ruby are not separately managed through mise merely because TeX utilities use them.

---

# Verification

Run:

```bash
./scripts/verify.sh
```

The verifier checks:

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

Every integration-style test uses temporary home, XDG, OS-release, and DMI
state. Package managers, firmware tooling, and service commands are either
blocked or mocked, so the harness never installs packages, enrolls keys,
changes real services, or writes to the user's configuration.

GitHub Actions runs these commands in a Fedora 44 container for every pull
request and every push to `main`. The workflow installs validation dependencies
inside the ephemeral container, but it never performs a workstation install or
changes firmware, Secure Boot, MOK enrollment, GPU/MUX settings, services, or
battery limits.

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

---

# Manual post-install checklist

After a fresh install:

1. Configure `~/.config/git/local`.
2. Optionally configure `~/.config/git/drdk`.
3. Configure SSH authentication.
4. Configure optional SSH commit signing.
5. Run `gh auth login`.
6. Start Neovim and allow lazy.nvim/Mason to complete setup.
7. Reboot after the initial installation so the desktop session observes the
   Zsh login-shell change. If an ASUS hardware profile also requested a reboot,
   use the same reboot; for the GA402XZ Secure Boot flow, complete MOK
   enrollment during it.
8. If Sway was installed, select it once at login and confirm the required
   outputs. Put any connector-specific rules in `~/.config/sway/local.conf`.

9. Run:

   ```bash
   ./scripts/verify.sh
   ```

   When a hardware profile is configured, this automatically includes its
   driver, service, DMI, and Secure Boot checks. For a focused rerun, use
   `./scripts/verify-asus-hardware.sh`.

10. Confirm Git identity:

   ```bash
   git config --show-origin --get user.name
   git config --show-origin --get user.email
   ```

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
Theme:                Catppuccin Macchiato
Accent:               Mauve
KDE decoration:       Classic
```

The goal is not to turn the workstation into a custom framework. The goal is a reproducible setup that remains understandable to someone already familiar with Fedora, Zsh, Neovim, Git, and the upstream tools themselves.
