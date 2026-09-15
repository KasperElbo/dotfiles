# Optional VM-guest profile

The normal Fedora bootstrap is also the guest bootstrap. Validation of its
composition found no reason to copy the Fedora installer or any Stow package:

| Area | Guest result |
|---|---|
| Portable dotfiles and developer tools | Reused unchanged |
| Fedora base and Terra packages | Reused unchanged |
| KDE theming | Reused unchanged |
| ASUS/NVIDIA laptop provisioning | Already opt-in; rejected when `--vm-guest` is selected |
| Power management | No guest override; laptop-specific masking runs only in the hardware profile |
| Networking | Left to the guest and hypervisor; the VM-host profile's default network supplies normal NAT/DHCP |
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

The Fedora VM-guest shell also exposes the exact guest-only shorthand
`x-copy='xclip -selection clipboard'`, so stdin can be copied directly:

```bash
printf 'hello' | x-copy
```

The alias is activated only when the verified VM-guest state file is present;
native Fedora workstation and Fedora WSL profiles do not receive it.

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
