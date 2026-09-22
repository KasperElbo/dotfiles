# Optional Fedora security-hardening profile

This is a conservative, explicit workstation-hardening profile, not the
[Parrot Security Edition CTF guest](../platforms/parrot-ctf.md) under
`platforms/parrot-ctf`. The Parrot guest is a disposable, offensive-security
lab environment; this profile does the opposite: it makes the everyday Fedora
host a little more resistant to local attacks while staying a normal
day-to-day development machine. The two are intentionally unrelated code
paths and are never installed together by the same flag.

It never disables SELinux or firewalld, never installs or enables an SSH
server, never changes firewalld zone services, never reboots, and never
touches UEFI/Secure Boot settings. The rule is that each change it makes is a
small, named, dotfiles-owned drop-in file, so that single change is rolled back
by deleting one file. Three changes are not drop-in files: the `SELINUX=` line
of `/etc/selinux/config`, the `authselect` `with-faillock` feature, and
`dnf5-automatic.timer`. Each of those has its own rollback in
[what the profile changes](#what-the-profile-changes) below. It is opt-in and
does not change the default install:

```bash
./install.sh --hardening
```

or, once the base workstation is already installed:

```bash
./platforms/fedora/scripts/install-hardening.sh
./platforms/fedora/scripts/install-hardening.sh --dry-run   # show the plan first
./platforms/fedora/scripts/verify-hardening.sh              # re-run verification any time
```

An interactive `./install.sh --hardening` asks you to agree to this profile
during preflight, before any step of the installation has run: the execution
plan has no way to skip a step, so a no asked later could only fail the run
once everything ahead of it had already been installed. Declining therefore
stops the run with nothing changed and nothing recorded. `--non-interactive`
does not ask, as everywhere else.

### Fedora's baseline (verified, not changed)

Fedora Workstation already provides real protection out of the box. This
profile verifies the following instead of reconfiguring it — `verify.sh`
checks the first two unconditionally, on every run, whether or not
`--hardening` was ever used:

| Protection | Fedora default | This profile |
|---|---|---|
| SELinux | Enforcing, targeted policy | Verified every `verify.sh` run; see below if it has drifted |
| firewalld | Enabled and active, default-deny inbound except the `FedoraWorkstation` zone's mDNS/dhcpv6-client/samba-client | Verified every `verify.sh` run; zone services are reported, not changed |
| ASLR, stack protector, `fs.protected_*`, TCP SYN cookies | Already on by default in Fedora's kernel/glibc/toolchain defaults | Not touched; there is nothing to add |
| Package integrity | DNF verifies GPG signatures on all configured repositories | Not touched |
| SSH server | Not installed on Fedora Workstation | Not installed by this profile either; see below |
| Automatic updates | Off; you update manually via `dnf`/GNOME Software/KDE Discover | Optionally switched to notify-only, never silent/automatic (see below) |
| Secure Boot | Machine-dependent; use the ASUS hardware profile's `--secure-boot` flag on supported laptops | Reported by `verify.sh`/`verify-hardening.sh`, never modified |

### What the profile changes

| Change | Rationale | Verify | Rollback | Compatibility |
|---|---|---|---|---|
| SELinux permissive → enforcing (only if currently permissive; a disabled system needs a manual relabel + reboot, so the installer warns instead of forcing one) | Keeps the acceptance criterion "SELinux remains enforcing" true even if it was manually loosened | `getenforce` | `sudo setenforce 0`, then restore the backup the installer kept beside the file: `sudo cp -a /etc/selinux/config.dotfiles-<epoch>.bak /etc/selinux/config`. This is the one vendor file the profile edits in place (SELinux has no drop-in mechanism); the edit touches only the `SELINUX=` line and is read back before the installer reports success | None for a workstation running its default targeted policy |
| `kernel.yama.ptrace_scope=1` (`/etc/sysctl.d/90-dotfiles-hardening.conf`) | Fedora ships `0`; `1` still allows a debugger to attach to its own child processes (gdb/lldb, VS Code, Neovim DAP, `dotnet` debuggers), only blocking attaching to an unrelated running process without root | `sysctl kernel.yama.ptrace_scope` | Delete the sysctl file, `sudo sysctl --system` | Attaching a debugger to an already-running, unrelated process needs `sudo`; launching and debugging your own process is unaffected |
| `kernel.kptr_restrict=2` | Fedora ships `0`; hides kernel pointers from `/proc` for non-root users, closing an info leak used to defeat KASLR | `sysctl kernel.kptr_restrict` | Delete the sysctl file, `sudo sysctl --system` | None for application-level development; only affects reading `/proc/kallsyms`-style kernel debugging as non-root |
| `kernel.dmesg_restrict=1` | Fedora ships `0`; requires `CAP_SYSLOG` to read the kernel ring buffer | `sysctl kernel.dmesg_restrict` | Delete the sysctl file, `sudo sysctl --system` | `dmesg` needs `sudo dmesg` afterward |
| `pam_faillock`: lock an account for 15 minutes after 5 failed password attempts (`authselect enable-feature with-faillock`, `/etc/security/faillock.conf.d/90-dotfiles-hardening.conf`) | Fedora ships no lockout at all; mitigates local password guessing against your login/sudo password | `authselect current` (look for `with-faillock`); `sudo faillock --user "$USER"` | `sudo authselect disable-feature with-faillock`; delete the faillock drop-in; `sudo faillock --user "$USER" --reset` clears an active lockout | Mistyping your password 5 times in a row locks the account for 15 minutes |
| sudo audit logfile (`Defaults logfile="/var/log/sudo.log"` in `/etc/sudoers.d/90-dotfiles-hardening`, validated with `visudo -cf` before install) | Fedora's default sudo keeps no dedicated audit trail beyond journald | `sudo test -f /etc/sudoers.d/90-dotfiles-hardening`; `sudo tail /var/log/sudo.log` | Delete the file | None; pure logging addition |
| `auditd` with a short watch list (`/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/sudoers`, `/etc/sudoers.d/`) | Fedora Workstation does not install `auditd`; watching identity/sudo files gives a tamper-evident trail for a small, fixed set of security-relevant files rather than full syscall auditing | `systemctl is-enabled auditd`; `systemctl is-active auditd`; `sudo auditctl -l` | `sudo systemctl disable --now auditd`; delete the rules file | A few file-write-triggered audit events; negligible CPU/disk cost next to full syscall auditing (which this profile deliberately does not enable) |
| Conservative sshd posture — **only if `sshd` is already active or enabled**: `PermitRootLogin no`, `MaxAuthTries 3`, `LoginGraceTime 20` (`/etc/ssh/sshd_config.d/90-dotfiles-hardening.conf`, validated with `sudo sshd -t` before reload) | Fedora Workstation does not install/enable an SSH server, so this profile never installs one just to harden it (per the design constraint); if you've enabled `sshd` yourself, these are small, config-scoped hardenings, not a rewrite of `sshd_config` | `sudo sshd -T` (check `permitrootlogin` and `maxauthtries`) | Delete the drop-in, `sudo systemctl reload sshd` | Only relevant if you already run `sshd`; password-only root login and unlimited auth retries stop working, key-based non-root login is unaffected |
| `dnf5-automatic.timer` (Fedora 41+ replaced dnf4's separate `dnf-automatic-notifyonly`/`-install`/`-download` timers with this single timer, whose behavior comes from `/etc/dnf/automatic.conf`; the packaged default `apply_updates = no`, `download_updates = yes` already means "download and report, never auto-install") | A developer workstation should not silently install or reboot on a schedule, but knowing updates are available is useful | `systemctl is-enabled dnf5-automatic.timer` | `sudo systemctl disable --now dnf5-automatic.timer`; `sudo dnf remove dnf5-plugin-automatic` if the installer pulled the package in and you want it gone | None; you still update manually, on your own schedule. If the timer is already enabled (any pre-existing policy, including a custom `apply_updates=yes` override), it's left alone rather than reconfigured |

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

### What verification proves

`verify-hardening.sh` is read-only and never asks for a password. Some of the
files this profile owns are `root:root` and mode `0440`/`0640`, and the loaded
audit ruleset can only be read as root, so verification does use `sudo` — but
every one of those calls is `sudo -n`. If there is no cached authorization it
reports the control as **not observed**, naming the file and saying to run
`sudo -v` first (or to run verification as root), and carries on with the
rest. That distinction is the point: a control the verifier could not read is
not a control that is gone, and reporting one as the other would send you to
reinstall a machine that is fine. It also means verification can run from a
script, a timer, or a session with no terminal to answer on without hanging on
a prompt.

"Read-only" is about configuration: nothing in verification writes, enables,
reloads or relabels anything. It is not a claim that the run leaves no trace.
Once this profile is installed, the `sudo` calls verification makes are
themselves logged to `/var/log/sudo.log`, and reading the audit rules is an
audited action, so a verification run shows up in the logs the profile turned
on. That is unavoidable for a privileged read and is not drift.

Every check sorts into one of four kinds, so a green run says exactly what it
means and nothing more:

| Kind | Examples | Result when unmet |
|---|---|---|
| **Repository-owned** | the `90-dotfiles-hardening` drop-ins under `sysctl.d`, `sudoers.d`, `faillock.conf.d`, `audit/rules.d` and `sshd_config.d`; `authselect`'s `with-faillock` feature; `auditd.service`; `dnf5-automatic.timer` | **Failure.** Each is checked for presence, the exact file mode the installer set, and the exact content it wrote — whole, against the same table the installer generated it from, because a line added above a policy line can reverse the policy while leaving every written line in place. Where a file can be present but inert, the effective state is checked too (`sysctl -n`, and every written rule in `auditctl -l`). Reverting one is drift, not a warning. |
| **Fedora baseline** | SELinux enforcing, `firewalld` enabled and active, private-key permissions | **Failure.** The installer verifies rather than changes these, but the profile's claims rest on them. |
| **Environmental** | Secure Boot state, SELinux unavailable inside a container, a machine where `authselect` could not enable faillock | **Warning**, with the reason. These depend on firmware, a vendor, or the host, not on this repository. |
| **Not observed** | a root-owned drop-in or the loaded audit ruleset on a machine with no cached `sudo` authorization | **Not verified**, and named in the output with what to run to check it. Counted separately from a pass, so the summary line says the run was incomplete. |
| **Manual assurance** | mount options, the service watch-list, the `ss -tuln` listening sockets, the exposed `firewalld` services and ports | **Not verified**, and labelled as such in the output. These are printed for a human to judge; a passing run asserts nothing about them. |

Owned checks run only when the profile was actually selected — that is, when
`$XDG_CONFIG_HOME/dotfiles/hardening.conf` records an installation. On a
machine that never installed the profile the absence of these files is
correct, not a defect, and verification says so instead of failing. If that
state file exists but cannot be read or validated, verification fails rather
than guessing what was applied.

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
| A single opaque "harden everything" script | Every change here is its own small, named, independently reversible change instead, a drop-in file wherever the subsystem has one, per the issue's own guidance to prefer small explicit changes |
