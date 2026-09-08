#!/usr/bin/env bash

# Fedora-on-WSL preflight helpers for the optional rootless Podman containers
# profile. Source common/lib/common.sh and lib/wsl.sh before this file.
#
# The actual install/verify logic (packages, subuid/subgid, the API socket,
# and the pull/run/build/mount/network/Compose smoke test) is Fedora's own
# platforms/fedora/scripts/install-containers.sh and verify-containers.sh,
# reused unchanged: none of that logic is WSL-specific. What WSL genuinely
# changes is the preconditions those scripts are allowed to assume, so this
# file checks the actual kernel/runtime capabilities involved (cgroup v2,
# unprivileged user namespaces, a running systemd) rather than sniffing a
# WSL/kernel version string, which would be fragile and easy to get wrong
# across WSL releases.

# cgroup_v2_available: true if the unified cgroup v2 hierarchy is mounted.
# Rootless Podman's default cgroup manager (systemd) requires this; WSL2
# kernels have shipped cgroup v2 by default for years, but a stale or
# customized kernel may not.
cgroup_v2_available() {
  local cgroup_root="${CGROUP_ROOT:-/sys/fs/cgroup}"
  [[ -f "$cgroup_root/cgroup.controllers" ]]
}

# user_namespaces_available: true if unprivileged user namespaces are
# enabled. Rootless Podman's subuid/subgid-mapped containers cannot start
# without them.
user_namespaces_available() {
  local max_user_ns_file="${MAX_USER_NAMESPACES_FILE:-/proc/sys/user/max_user_namespaces}"
  local value

  [[ -r "$max_user_ns_file" ]] || return 1
  value="$(<"$max_user_ns_file")"
  [[ "$value" =~ ^[0-9]+$ ]] && ((value > 0))
}

# systemd_user_session_available: true if a systemd --user D-Bus session
# bus is reachable for the invoking user. Confirmed against real Fedora
# WSL: systemd as PID 1 (systemd_is_running) is necessary but NOT
# sufficient -- WSL does not open a full login/PAM session by default, so
# no systemd --user instance attaches to the UID, and $XDG_RUNTIME_DIR/bus
# never appears, unless lingering is enabled (loginctl enable-linger) or a
# real login session was started. Without this bus, rootless Podman falls
# back to --cgroup-manager=cgroupfs and fails to track the pause process it
# uses to keep a rootless container network namespace alive, which breaks
# `podman network create`, builds that run the built image, and Compose,
# even though `podman version`/`info` and non-networked operations (pull,
# a plain run, bind mounts, named volumes) keep working.
systemd_user_session_available() {
  local bus_socket="${SYSTEMD_USER_BUS_SOCKET:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus}"
  [[ -e "$bus_socket" ]]
}

# require_wsl_containers_prereqs: hard-fails with an actionable message if
# this Fedora WSL instance cannot support the containers profile. Unlike the
# rest of the Fedora WSL profile (which treats systemd as optional, see
# lib/wsl.sh's systemd_is_running), this profile requires it: podman.socket
# is a systemd --user unit, and rootless Podman's default cgroup manager
# needs a real systemd user instance to delegate cgroup v2 controllers to.
require_wsl_containers_prereqs() {
  require_fedora_wsl

  systemd_is_running || die "$(
    cat <<'EOF'
The containers profile requires systemd as PID 1 inside Fedora WSL.

podman.socket is a systemd --user unit, and rootless Podman's default
cgroup manager needs a running systemd --user instance to delegate cgroup
v2 controllers, even when the API socket is not enabled. Enable systemd in
this WSL distribution, then retry:

  1. Add to /etc/wsl.conf:
       [boot]
       systemd=true
  2. From Windows PowerShell: wsl --shutdown
  3. Reopen this Fedora WSL distribution.
EOF
  )"

  systemd_user_session_available || die "$(
    cat <<'EOF'
systemd is PID 1, but no systemd --user session (D-Bus bus) is reachable
for this account.

WSL does not open a full login/PAM session by default, so nothing starts
your systemd --user instance even with systemd=true set. Without it,
rootless Podman falls back to a cgroupfs cgroup manager and cannot track
the pause process it uses to keep a rootless container network namespace
alive -- builds that run the built image, `podman network create`, and
Compose all fail this way, even though `podman version`/`info`, pulls,
plain runs, bind mounts, and named volumes keep working. Fix it with
either:

  - Enable lingering once (starts your user instance at boot,
    independent of logging in):
      sudo loginctl enable-linger "$(id -un)"
    then from Windows PowerShell: wsl --terminate <DistroName>, and
    reopen the distribution.
  - Or open a real login session (not just a WSL shell attach) so PAM
    starts the user instance, e.g. via `wsl.exe` from a fresh terminal
    rather than an already-attached one.
EOF
  )"

  cgroup_v2_available || die "$(
    cat <<'EOF'
cgroup v2 unified hierarchy not found (no cgroup.controllers under
/sys/fs/cgroup). Rootless Podman's systemd cgroup manager requires it.
Update the WSL2 kernel from Windows PowerShell: wsl --update
EOF
  )"

  user_namespaces_available || die "$(
    cat <<'EOF'
Unprivileged user namespaces are disabled or unavailable
(/proc/sys/user/max_user_namespaces). Rootless Podman cannot map container
UIDs/GIDs without them. Update the WSL2 kernel from Windows PowerShell:
wsl --update
EOF
  )"
}

# wsl_networking_mode_hint: best-effort, informational only. WSL2's default
# NAT networking gives the distribution a single virtual adapter; the newer
# mirrored networking mode (Windows 11 23H2+, .wslconfig
# "networkingMode=mirrored") instead mirrors the host's own adapters into
# WSL, so more than one non-loopback interface is typically visible. Podman's
# own rootless container network (netavark/aardvark-dns, pasta/slirp4netns)
# is entirely internal to this WSL instance's Linux network namespace and is
# unaffected either way; what the networking mode actually changes is
# Windows-to-WSL localhost port forwarding, which is why this is reported as
# a hint rather than gating anything.
wsl_networking_mode_hint() {
  local ip_command="${IP_COMMAND:-ip}"
  local interface_count

  command_exists "$ip_command" || return 0

  interface_count="$(
    "$ip_command" -o -4 addr show up scope global 2>/dev/null | wc -l
  )"

  if ((interface_count <= 1)); then
    printf 'single non-loopback IPv4 interface (consistent with WSL2 default NAT networking)\n'
  else
    printf 'multiple non-loopback IPv4 interfaces (consistent with WSL2 mirrored networking mode)\n'
  fi
}
