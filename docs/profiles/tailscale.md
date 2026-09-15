# Optional Tailscale networking profile

`--tailscale` installs the Tailscale client (the `tailscale`
CLI and the `tailscaled` service) as an optional networking profile. It is
not part of the default `./install.sh` path, appears in `--dry-run`, and can
be installed and reverified independently of the rest of the workstation:

```bash
./install.sh --tailscale
./platforms/fedora/scripts/install-tailscale.sh
./platforms/fedora/scripts/install-tailscale.sh --dry-run   # show the plan first
./platforms/fedora/scripts/verify-tailscale.sh              # re-run verification any time
```

This profile installs and enables the local client only. Everything
account/tailnet-specific — logging in, ACLs, exit nodes, subnet routes,
device tags, Tailscale SSH — is deliberately left to you, interactively,
outside this repository. Nothing here embeds a reusable auth key, an OAuth
client secret, a node key, or any tailnet policy.

On **Fedora** (and Fedora WSL), verification is read-only and keeps three
outcomes separate: a **connected** tailnet (`BackendState: Running`); a valid
**installed but not authenticated** machine (`NeedsLogin`, `NoState`,
`Stopped`, `Starting`, `NeedsMachineAuth`), which passes with the exact
command needed to finish connecting; and a state that **could not be
determined**, which fails. That last group is the reason this profile's
verification exists in the form it does: a missing or unusable `jq` (the
declared JSON parser), a `tailscale status --json` call that fails while
`tailscaled` is up, malformed JSON, an absent `BackendState`, or a backend
state the verifier does not recognize all mean the connection state was
never actually read, so none of them may report success. Verification never
runs `tailscale up` or otherwise changes tailnet state.

**macOS's verifier is weaker by design**: an unrecognized `BackendState`, or
a `tailscale status --json` call that does not respond, is reported as a
**warning**, not a failure — see [the macOS section](#macos) below.

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

Per this profile's own boundary, none of the following are set, enabled, or
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

On macOS, `--platform macos
--tailscale` installs Tailscale as the supported **Standalone** macOS app
(Homebrew cask `tailscale-app`, a sandboxed Network Extension app, not a
`tailscaled` systemd-style service — macOS has no systemd). Authentication
stays interactive by opening the app; nothing here scripts macOS's Network
Extension permission grant or the tailnet login. See [the macOS
guide](../platforms/macos.md#optional-tailscale) for the full command-line/CLI
integration notes and verification details.

The saved local state file is:

```text
~/.config/dotfiles/macos-tailscale.conf
```
