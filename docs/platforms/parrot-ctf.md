# Parrot Security Edition CTF guest

This variant is an intentionally disposable security-lab guest. Parrot
Security Edition supplies and updates its own pentesting catalogue through its
configured APT repositories; this repository supplies only the surrounding
working environment. It neither enumerates nor reinstalls Parrot's offensive
tools.

Use the Parrot Security Edition ISO or QCOW2 image with the
[Fedora VM-host profile](../profiles/vm-host.md). The reference guest keeps the same `qemu:///system` backend, qcow2
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
# Log out of the graphical session and back in once after the first install.
./platforms/parrot-ctf/scripts/verify.sh
./install.sh --platform parrot-ctf --non-interactive
```

The first install makes the invoking non-root account's registered Zsh the
login shell. Konsole inherits that account shell naturally; its managed
`Dotfiles-Parrot-CTF.profile` deliberately has no `Command=` override. The
profile installs pinned Hack Nerd Font Mono 3.5.1 user-locally, selects it in
Konsole, and installs the four pinned Catppuccin bat themes referenced by the
shared Git/Delta configuration. It does not install Ghostty or apply general
KDE theming.

## Terminal

The guest's terminal is Parrot's own **Konsole**, configured rather than
replaced: `install-terminal.sh` installs pinned Hack Nerd Font Mono
user-locally, selects it in the managed `Dotfiles-Parrot-CTF.profile`, and
installs the pinned Catppuccin bat themes. Ghostty is deliberately not
installed here, and no general KDE theming is applied.

The managed profile sets the font and nothing else. It declares no
`ColorScheme=`, and this guest has no theme hook, so the terminal's palette
stays whatever Parrot ships and the selected Catppuccin flavour does not reach
it — which is why `config/capabilities.tsv` records this capability's provider
as `repository+upstream-font-only` rather than as a themed terminal.

The final rerun is the idempotency check. Without `--theme`, it preserves an
existing valid flavour; an explicit `--theme FLAVOUR` changes it. The guest
verifier checks observable guest state: Parrot and KVM/QEMU detection, both
virtio channels, account shell, Zsh startup, APT ownership and command
resolution, guest services, portable links, exact reduced Mason inventory,
Neovim version/profile, unique PATH entries, font/glyph coverage, effective
Konsole profile, bat themes, and Starship compatibility. Its state file is a
record of installer intent, not proof of host isolation.

Run the effective isolation check on the Fedora/libvirt host with an explicit
domain selector:

```bash
./platforms/fedora/scripts/verify-parrot-isolation.sh --domain parrot-ctf
virsh --connect qemu:///system domifaddr parrot-ctf --source agent
```

The host check inspects the selected domain, network, and storage-pool XML. It
fails on bridged/non-policy interfaces, filesystem passthrough, likely
SSH/GPG/password-manager agent channels, host USB/PCI devices, missing guest
integration channels, non-NAT forwarding, or file-backed disks outside the
selected pool. Output separates `VERIFIED`, `NOT OBSERVED`, and
`MANUAL ASSURANCE REQUIRED`. Clipboard client policy, secrets entered or
stored inside the guest, and host firewall/physical-network trust remain
manual assurances because libvirt XML cannot establish them.

Parrot owns Python, `venv`, pip, pipx, and the security-tool catalogue. mise
owns `uv` and one explicit exception: pinned Neovim 0.12.5 from the current
`github:neovim/neovim` backend, because Parrot 7.3's APT/backports Neovim 0.10.x
cannot run the tracked LazyVim baseline. The effective `nvim` must resolve
through mise; `python`, `python3`, and installed security tools must not.

The Parrot editor profile restores only core LazyVim plus Python testing and
debugging. Its exact Mason inventory is basedpyright, debugpy,
lua-language-server, Ruff, Stylua, and the Tree-sitter CLI required by
LazyVim's core syntax support. It deliberately excludes .NET, Node, Angular,
TeX, Markdown-preview, and other general workstation integrations.
Its separate tracked lockfile prevents a reduced restore from rewriting the
workstation plugin lock. After the bootstrap phase, the pinned plugin lock and managed tools support
offline editor startup; automatic Lazy plugin update checking is disabled for
this profile. Add challenge-specific runtimes in the challenge repository,
not the machine-wide Parrot mise manifest. Use `uv init`/`uv sync`, a local
`.venv`, or pipx rather than installing challenge packages into Parrot's
system Python.

Opting into the full workstation editor is explicit and does not mutate the
Parrot base profile: launch with `DOTFILES_NVIM_PROFILE=workstation nvim`, then
provision any extra runtimes and Mason packages that profile needs yourself.
Remove the override to return to the reduced profile selected by the stowed
marker. Prefer project-local Lazy specs when only one challenge needs an extra
editor integration.

The shared Zsh environment remains authoritative for generic shell behavior.
Parrot's Bash aliases are not sourced wholesale; only the reviewed
`hex-encode`, `hex-decode`, and `rot13` CTF helpers are retained. The profile
uses `unsetopt NOMATCH`: unmatched wildcard-looking payload/URL arguments pass
through as they do in Bash, while patterns matching local files still expand.
See [the source-by-source shell audit](../parrot-ctf-shell-audit.md) for the
classification and trade-off analysis.

Parrot's early shell hook retains `/usr/local/sbin`, `/usr/sbin`, and `/sbin`,
and retains `/snap/bin` only when that directory exists. Zsh's unique tied
PATH array removes inherited duplicates while keeping existing order. The
later mise activation may put only the approved `nvim` and `uv` exceptions
first; `python`, `python3`, and security tools such as `john` continue to
resolve to APT-owned system paths. Sourcing the hook repeatedly is idempotent.

For the graphical guest clipboard, `x-copy` expands exactly to
`xclip -selection clipboard`:

```bash
printf 'hello' | x-copy
```

It exists only in the Parrot and Fedora VM-guest profiles and does not replace
`wl-copy`. A printable reduced profile reference is available from
`docs/cheatsheets/parrot-ctf.tex`.
