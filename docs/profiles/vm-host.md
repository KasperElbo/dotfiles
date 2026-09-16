# Optional VM-host profile

`--vm-host` adds Fedora's native KVM/QEMU + libvirt virtualization stack. It
is not part of the default `./install.sh` path, appears in `--dry-run`, and
can be installed and reverified independently of the rest of the
workstation:

```bash
./install.sh --vm-host
./platforms/fedora/scripts/install-vm-host.sh
./platforms/fedora/scripts/verify-vm-host.sh --smoke-test
```

`--vm-host` and `--vm-guest` are mutually exclusive: `config/capabilities.tsv`
declares each as conflicting with the other, and the Fedora installer refuses
a run that selects both, because a VM host and a VM guest bootstrap are
different, non-overlapping roles for the same machine.

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

Where Fedora provides the standard `libvirt` group, the installer adds the
installing user to it. That membership is **root-equivalent**: it grants
passwordless read-write access to `qemu:///system`, so a member can define a
guest whose disk is a raw host block device such as `/dev/nvme0n1` and read or
write that whole disk through the root-owned QEMU process. Adding the
workstation's owner is a deliberate choice for a single-user machine, not an
oversight, and it is disclosed both in the `--dry-run` plan and when the change
is made. After the group change, log out and back in before using
`qemu:///system`.

To roll it back, remove the membership, then log out and back in:

```bash
sudo gpasswd -d "$USER" libvirt
```

Without the group, Fedora's upstream libvirt/polkit policy still lets an
administrator use `qemu:///system`, with an authentication prompt each session
instead. Prefer that posture by removing the membership as above; a later
`--vm-host` rerun adds it back. Independently of the group, the installer
never makes the libvirt socket world-writable and installs no polkit rule of
its own.

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
or storage pools on rerun or rollback. Any later guest provisioning must reuse
this libvirt system backend and these storage/network conventions rather than
add a second provisioning path.
