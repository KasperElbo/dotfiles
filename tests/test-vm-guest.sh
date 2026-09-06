#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
mkdir -p \
  "$mock_bin" \
  "$test_root/home" \
  "$test_root/xdg" \
  "$test_root/virtio-ports"

cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
EOF

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  '-q qemu-guest-agent' | '-q spice-vdagent' | '-q xclip') exit 0 ;;
esac
exit 1
EOF

cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
  'is-active --quiet qemu-guest-agent.service' | \
    'is-active --quiet spice-vdagentd.socket' | \
    '--user is-active --quiet spice-vdagent.service') exit 0 ;;
  '--user is-active --quiet dotfiles-spice-wayland-clipboard.service') exit 1 ;;
esac
exit 0
EOF

cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
"$@"
EOF

cat >"$mock_bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'default via 192.168.122.1 dev enp1s0 proto dhcp\n'
EOF

cat >"$mock_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_VIRTUALIZATION_TYPE:-kvm}"
[[ "${MOCK_VIRTUALIZATION_TYPE:-kvm}" != none ]]
EOF

chmod +x "$mock_bin"/*

printf 'ID=fedora\n' >"$test_root/os-release"
touch \
  "$test_root/virtio-ports/org.qemu.guest_agent.0" \
  "$test_root/virtio-ports/com.redhat.spice.0"

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/xdg"
  "XDG_DATA_HOME=$test_root/home/.local/share"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "OS_RELEASE_FILE=$test_root/os-release"
  "QEMU_AGENT_CHANNEL=$test_root/virtio-ports/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$test_root/virtio-ports/com.redhat.spice.0"
)

run_install() {
  "${test_environment[@]}" "$repo_root/scripts/install-vm-guest.sh" >/dev/null
}

legacy_clipboard_bridge="$test_root/xdg/systemd/user/dotfiles-spice-wayland-clipboard.service"
mkdir -p "$(dirname "$legacy_clipboard_bridge")"
printf '[Service]\nExecStart=/usr/bin/false\n' >"$legacy_clipboard_bridge"

run_install
state_file="$test_root/xdg/dotfiles/vm-guest.conf"
first_state="$(sha256sum "$state_file")"
run_install
second_state="$(sha256sum "$state_file")"

[[ "$first_state" == "$second_state" ]]
grep -Fqx 'profile=vm-guest' "$state_file"
grep -Fqx 'hypervisor=kvm' "$state_file"
grep -Fqx 'guest_agent=qemu-guest-agent' "$state_file"
grep -Fqx 'desktop_agent=spice-vdagent' "$state_file"
grep -Fqx 'display=spice' "$state_file"
grep -Fqx 'network=host-managed' "$state_file"
grep -Fqx 'shared_folders=manual' "$state_file"
grep -Fq 'sudo dnf install -y qemu-guest-agent spice-vdagent xclip' "$command_log"
grep -Fq \
  'sudo systemctl enable --now qemu-guest-agent.service' "$command_log"
grep -Fq \
  'sudo systemctl start spice-vdagentd.socket' "$command_log"
grep -Fq \
  'systemctl --user disable --now dotfiles-spice-wayland-clipboard.service' \
  "$command_log"
[[ ! -e "$legacy_clipboard_bridge" ]]

if grep -Eiq 'asus|nvidia|power-profile|brctl|nmcli' "$command_log"; then
  printf 'VM-guest profile changed hardware, power, or networking configuration.\n' >&2
  exit 1
fi

verification_output="$(
  "${test_environment[@]}" "$repo_root/scripts/verify-vm-guest.sh" 2>&1
)"
grep -Fq 'Virtual machine detected: kvm' <<<"$verification_output"
grep -Fq 'Guest has a default network route' <<<"$verification_output"
grep -Fq 'VM-guest verification passed.' <<<"$verification_output"

before_rejection="$(sha256sum "$command_log")"
if "${test_environment[@]}" \
  env MOCK_VIRTUALIZATION_TYPE=none \
  "$repo_root/scripts/install-vm-guest.sh" >"$test_root/bare-metal.log" 2>&1; then
  printf 'VM-guest install unexpectedly accepted bare metal.\n' >&2
  exit 1
fi
grep -Fq 'must be run inside a detected virtual machine' \
  "$test_root/bare-metal.log"
[[ "$(sha256sum "$command_log")" == "$before_rejection" ]]

if "${test_environment[@]}" \
  env MOCK_VIRTUALIZATION_TYPE=none \
  "$repo_root/install.sh" --vm-guest --no-kde --no-latex --non-interactive \
  >"$test_root/top-level-bare-metal.log" 2>&1; then
  printf 'Top-level installer unexpectedly accepted a VM guest on bare metal.\n' >&2
  exit 1
fi
grep -Fq 'must be run inside a detected virtual machine' \
  "$test_root/top-level-bare-metal.log"
[[ "$(sha256sum "$command_log")" == "$before_rejection" ]]

if "${test_environment[@]}" \
  env MOCK_VIRTUALIZATION_TYPE=vmware \
  "$repo_root/scripts/install-vm-guest.sh" >"$test_root/unsupported.log" 2>&1; then
  printf 'VM-guest install unexpectedly accepted an unsupported hypervisor.\n' >&2
  exit 1
fi
grep -Fq 'currently supports KVM/QEMU guests; detected vmware' \
  "$test_root/unsupported.log"
[[ "$(sha256sum "$command_log")" == "$before_rejection" ]]

dry_run_root="$test_root/dry-run"
mkdir -p "$dry_run_root"
dry_run_output="$(
  HOME="$dry_run_root" \
    XDG_CONFIG_HOME="$dry_run_root/config" \
    "$repo_root/scripts/install-vm-guest.sh" --dry-run
)"
grep -Fq 'qemu-guest-agent' <<<"$dry_run_output"
grep -Fq 'spice-vdagent' <<<"$dry_run_output"
grep -Fq 'xclip' <<<"$dry_run_output"
if grep -Fq 'wl-paste --watch' <<<"$dry_run_output"; then
  printf 'VM-guest dry-run unexpectedly included the rejected clipboard watcher.\n' >&2
  exit 1
fi
[[ -z "$(find "$dry_run_root" -mindepth 1 -print -quit)" ]]

printf 'VM-guest detection, integration, networking, and idempotency tests passed.\n'
