# Fedora workstation

The Fedora workstation is the reference target: everything portable is
developed here first. This guide covers what is specific to a physical Fedora
machine — optional laptop hardware support, keyboard layouts, and the optional
Sway session. The install path itself is in
[install.md](../workflows/install.md), and the optional profiles that are not
Fedora-specific have their own guides under [profiles/](../profiles/).

## ASUS laptop hardware

Hardware setup is deliberately separate from the default workstation install.
It currently supports these ROG Zephyrus G14 profiles:

| Profile | Laptop | Graphics stack |
|---|---|---|
| `ga402xz` | 2023 GA402XZ | Fedora AMD iGPU plus RPM Fusion NVIDIA akmod |
| `ga402rk` | 2022 GA402RK, including GA402RK-L81152 | Fedora AMD firmware, kernel `amdgpu`, and Mesa |

Enable it as part of the main installer with `--hardware`:

```bash
./install.sh --hardware ga402xz --secure-boot --charge-limit 80
```

Or run the component directly when the workstation configuration is already
installed:

```bash
./platforms/fedora/scripts/install-asus-hardware.sh \
  --model ga402xz \
  --secure-boot \
  --charge-limit 80

./platforms/fedora/scripts/install-asus-hardware.sh \
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
./platforms/fedora/scripts/install-asus-hardware.sh \
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
./platforms/fedora/scripts/verify-asus-hardware.sh
```

## SFTP client

Command-line SFTP is part of the base workstation install; no installer flag
is required. It comes from Fedora's own `openssh-clients` package — the same
package that provides `ssh` and `scp` — so there is never a second SSH
implementation to manage. This is Fedora-specific: the base package list on
other platforms differs (Parrot's base install, for example, has no
`openssh-client`/`openssh-clients` row of its own).

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

**Sway**: the optional `--sway` session (see "Optional Sway session" below)
runs on top of the same Fedora KDE Plasma base as the rest of this profile,
so Dolphin and the `kio-extras` sftp:// support ensured above are available
there too — launch Dolphin from Fuzzel exactly as under Plasma. No dedicated
Sway-specific GUI SFTP client is added, since Dolphin already solves the same
usability gap in both sessions.

A standalone GUI client such as FileZilla was evaluated and rejected: Dolphin
already gives both KDE and Sway a working native SFTP path with SSH key/agent
support, drag/drop, and recursive transfers, so a second GUI application would
duplicate functionality rather than close a real gap.

## Keyboard layouts

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

These entries are part of the shared KDE/Sway keyboard workflow and are
included in the [Fedora KDE](../cheatsheets/fedora-kde.tex) and
[Fedora Sway](../cheatsheets/fedora-sway.tex) printable cheat sheets from
the printable [cheat sheets](../cheatsheets/README.md).

---

## Optional Sway session

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
