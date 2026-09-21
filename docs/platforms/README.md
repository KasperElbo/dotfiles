# Supported platforms and profiles

Four platforms this repository builds a workstation on, one portable core, and
the Windows host that carries one of them. This page records what is supported,
what is deliberately out of scope, and where each platform's own guide lives.

| Platform | Guide |
|---|---|
| Fedora workstation | [fedora.md](fedora.md) |
| Fedora on WSL | [fedora-wsl.md](fedora-wsl.md) |
| Apple Silicon macOS | [macos.md](macos.md) |
| Parrot Security Edition CTF guest | [parrot-ctf.md](parrot-ctf.md) |
| Windows host (WSL 2, terminal, dictation) | [windows.md](windows.md) |

The first four are `./install.sh --platform` names. The Windows host is not: it
is installed by `platforms\windows\install.ps1` and verified by
`platforms\windows\verify.ps1`, and it is in the registry on the same terms as
the others.

Which capability each platform actually has, and who provides it, is generated
from `config/capabilities.tsv` into
[../reference/capability-matrix.md](../reference/capability-matrix.md).

## Supported environment

The workstation configuration has been developed and tested on:

- Fedora 44
- macOS Tahoe 26 on Apple Silicon (`arm64`)
- KDE Plasma on Wayland
- Sway on Wayland when installed with `--sway`
- Zsh
- Ghostty
- Neovim 0.12+ (the enforced floor is recorded in
  [`config/tool-floors.tsv`](../../config/tool-floors.tsv))
- GNU Stow

The optional guest profiles target Fedora 44 and Parrot Security Edition 7.3
KVM/QEMU guests managed by libvirt, with virt-manager as the normal graphical
client. Parrot is a CTF/lab guest, not a general-purpose workstation target.

The supported Linux bootstraps are Fedora 44 Workstation-class installed
systems (Fedora Workstation or Fedora KDE Plasma Desktop) and the official
Fedora distribution running under WSL 2. Minimal, CoreOS, cloud, and container
images are not workstation bootstrap targets. A supported Fedora workstation
must provide the normal installed-system foundation: Bash, DNF/RPM, sudo,
systemd, GNU core utilities, Gawk, findutils, grep, sed, and Git. The installer
checks that foundation before its first mutation, then explicitly installs
every remaining baseline provider, including firewalld and GnuPG. The official
Fedora WSL image additionally owns `wslpath`; Windows owns the explicitly
invoked `.exe` interop endpoints. The WSL variant is a Linux development
runtime: it deliberately does not reproduce the Fedora desktop, laptop, GPU or
virtualization-host setup inside WSL.

The macOS bootstrap targets `/opt/homebrew` on Apple Silicon and uses AeroSpace
for a Sway-like nine-workspace model without disabling SIP. See the complete
[Apple Silicon macOS workstation guide](macos.md).
