# Fedora Development Dotfiles

Opinionated, reproducible dotfiles for a keyboard-driven development workstation built around:

- Fedora
- KDE Plasma / Wayland, with an optional Sway session
- Ghostty
- Zsh
- Neovim + LazyVim
- tmux
- Git + GitHub CLI + Lazygit
- mise-managed language runtimes
- Catppuccin across the desktop, terminal, editor, and CLI tools

The configuration is intended to stay close to upstream defaults. Custom behavior is added only where it solves a concrete workflow problem.

The current default Catppuccin flavor is **Macchiato** with the **Mauve** accent.

## Design principles

1. **Use the native package manager for machine-level tools.** Fedora/DNF owns operating-system and desktop-integrated tools.
2. **Use mise for language runtimes and portable developer CLIs.**
3. **Use Mason only for Neovim-specific tooling.**
4. **Keep project tooling in the project.** CSharpier, Prettier, ESLint, `dotnet-ef`, TypeScript, etc. should normally be declared by the repository that uses them.
5. **Keep shared configuration tracked and user-specific state local.**
6. **Prefer upstream workflows over custom glue.**

---

# Supported environment

This configuration has been developed and tested on:

- Fedora 44
- KDE Plasma on Wayland
- Sway on Wayland when installed with `--sway`
- Zsh
- Ghostty
- Neovim 0.12+
- GNU Stow

The supported machine bootstrap is currently Fedora-only. The portable layer
has its own entry points so future macOS or WSL installers can reuse it without
copying configuration; those installers are intentionally not implemented yet.

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

## Installer options

```text
--theme FLAVOUR    latte | frappe | macchiato | mocha
                   default: macchiato

--kde              install Catppuccin KDE integration
--no-kde           skip KDE integration

--latex            install the LaTeX toolchain
--no-latex         skip the LaTeX toolchain

--sway             install the optional keyboard-driven Sway session
--no-sway          skip Sway (default)

--vm-host          install the optional KVM/QEMU + libvirt VM-host profile

--hardware MODEL   install ASUS hardware support for ga402xz or ga402rk
                   default: disabled
--secure-boot      require Secure Boot for the selected hardware profile
--charge-limit N   set ASUS battery charge limit (40-100 percent)

--dry-run          print the installation plan only
--non-interactive  use defaults without prompting

-h, --help         show help
```

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

The repository has two ownership layers:

| Layer | Owns | Must not own |
|---|---|---|
| Portable common | Shared Stow packages, user-local Git/theme state, mise tools, and the tmux theme | Package managers, services, hardware, desktop integration, or OS-specific paths |
| `platforms/fedora` | DNF/Terra packages, KDE and Sway integration, system services, SELinux/system paths, Secure Boot, and ASUS hardware | Copies of shared Zsh/Git/Neovim/tmux/mise configuration |

The shared Stow package directories remain at the repository root to preserve
existing symlink targets. `common/stow.sh` is their authoritative package
manifest and deployment entry point. A future platform installer should call
the common scripts directly and then add only its own integration layer.

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
    ├── platforms/fedora/scripts/install-asus-hardware.sh  optional
    ├── platforms/fedora/scripts/install-sway.sh           optional
    ├── common/setup-local.sh
    ├── platforms/fedora/scripts/setup-local.sh
    ├── common/stow.sh
    ├── platforms/fedora/scripts/stow.sh
    ├── common/install-mise.sh
    ├── common/install-tmux-theme.sh
    ├── platforms/fedora/scripts/install-kde-theme.sh      optional
    ├── platforms/fedora/scripts/install-latex.sh          optional
    ├── platforms/fedora/scripts/install-vm-host.sh        optional
    ├── ~/.local/bin/theme + Fedora theme hook
    └── platforms/fedora/scripts/verify.sh
```

The historical `scripts/*.sh` paths remain thin compatibility entry points for
Fedora. Component scripts are individually callable and safe to rerun.

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
or booting a guest. To boot a real guest, supply an installer ISO explicitly,
for example:

```bash
virt-install \
  --connect qemu:///system \
  --name fedora-test \
  --memory 4096 \
  --vcpus 4 \
  --disk size=40,format=qcow2,bus=virtio \
  --network network=default,model=virtio \
  --graphics spice \
  --boot uefi \
  --cdrom ~/Downloads/Fedora.iso
```

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

## Terra RPM repository

The reference setup uses Terra packages for:

```text
ghostty
mise
starship
```

These remain RPM-owned. mise itself is **not** installed by mise.

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

The four tracked 3840x2160 wallpapers form a flavour-matched tropical-island
day-to-night cycle adapted from the MIT-licensed Catppuccin wallpaper
collection. Swaylock uses a separately tracked blurred and darkened derivative
of the active wallpaper. The exact upstream revision and license are recorded
beside the assets and in `LICENSES/Catppuccin.txt`.

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

## Disposable workflow validation

The repository includes network-dependent fixtures that exercise real project
tooling in temporary directories:

```bash
./scripts/test-dev-workflows.sh
./scripts/test-dev-workflows.sh --angular
./scripts/test-dev-workflows.sh --python
```

The Angular check installs only fixture-local dependencies, formats, lints,
tests, exercises both the modern and debug builds with source maps, starts the
debug server, and probes it.
The Python check resolves an isolated environment, runs the package and tests,
lints, checks formatting, and builds both source and wheel distributions. These
larger download-based checks are intentionally separate from `scripts/test.sh`;
the normal repository suite validates their configuration without fetching
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
- Catppuccin tmux installation/version
- optional ASUS hardware profile, drivers, services, and Secure Boot state
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
preservation of unrelated user files and symlinks. It also exercises GA402XZ
and GA402RK hardware preflights, fail-before-mutation behavior, and
representative package and service flows through command mocks.

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
7. If an ASUS hardware profile requested a reboot, perform it now. For the
   GA402XZ Secure Boot flow, complete MOK enrollment during that reboot.
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
Theme:                Catppuccin Macchiato
Accent:               Mauve
KDE decoration:       Classic
```

The goal is not to turn the workstation into a custom framework. The goal is a reproducible setup that remains understandable to someone already familiar with Fedora, Zsh, Neovim, Git, and the upstream tools themselves.
