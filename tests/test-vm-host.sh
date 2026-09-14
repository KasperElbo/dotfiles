#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" "$test_root/kvm"

test_stub_init "$test_root"
for command_name in dnf sudo systemctl; do
  test_stub_install "$test_root" "$command_name"
done
vm_host_packages=(
  edk2-ovmf libvirt-client libvirt-daemon-config-network
  libvirt-daemon-driver-qemu qemu-img qemu-kvm spice-gtk spice-server swtpm
  swtpm-tools virt-install virt-manager virt-viewer
)
test_stub_allow "$test_root" dnf install -y "${vm_host_packages[@]}"
test_stub_allow "$test_root" sudo dnf install -y "${vm_host_packages[@]}"
test_stub_allow "$test_root" systemctl cat libvirtd.service
test_stub_allow "$test_root" systemctl enable --now libvirtd.service
test_stub_allow "$test_root" sudo systemctl enable --now libvirtd.service
test_stub_allow "$test_root" sudo virsh -c qemu:///system net-autostart default
test_stub_allow "$test_root" sudo virsh -c qemu:///system pool-autostart default

cat >"$test_root/handlers/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
EOF

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF

cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF

cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == group && "$2" == libvirt ]]
EOF

cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -nG ]]; then
  printf 'tester libvirt\n'
else
  printf 'tester\n'
fi
EOF

cat >"$mock_bin/virsh" <<'EOF'
#!/usr/bin/env bash
printf 'virsh %s\n' "$*" >>"$COMMAND_LOG"
case "$*" in
  *' uri') printf 'qemu:///system\n' ;;
  *' net-info default') printf 'Active: yes\nAutostart: yes\n' ;;
  *' pool-info default') printf 'State: running\nAutostart: yes\n' ;;
esac
EOF

cat >"$mock_bin/virt-host-validate" <<'EOF'
#!/usr/bin/env bash
printf 'virt-host-validate %s\n' "$*" >>"$COMMAND_LOG"
printf "QEMU: Checking for cgroup 'devices' controller support : WARN\n"
printf 'QEMU: Checking for secure guest support : WARN\n'
exit 0
EOF

cat >"$mock_bin/virt-install" <<'EOF'
#!/usr/bin/env bash
printf 'virt-install %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF

cat >"$mock_bin/install" <<'EOF'
#!/usr/bin/env bash
printf 'install %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF

for command_name in qemu-img virt-manager virt-viewer; do
  ln -s virt-host-validate "$mock_bin/$command_name"
done

chmod +x "$mock_bin"/* "$test_root/handlers"/*
printf 'ID=fedora\n' >"$test_root/os-release"
touch "$test_root/kvm/device"

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/xdg"
  "XDG_DATA_HOME=$test_root/home/.local/share"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "OS_RELEASE_FILE=$test_root/os-release"
  "KVM_DEVICE=$test_root/kvm/device"
  "USER=tester"
)

run_install() {
  "${test_environment[@]}" "$repo_root/scripts/install-vm-host.sh" >/dev/null
}

run_install
state_file="$test_root/xdg/dotfiles/vm-host.conf"
first_state="$(sha256sum "$state_file")"
run_install
second_state="$(sha256sum "$state_file")"

[[ "$first_state" == "$second_state" ]]
grep -Fqx 'profile=vm-host' "$state_file"
grep -Fqx 'libvirt_uri=qemu:///system' "$state_file"
grep -Fqx 'network_mode=nat' "$state_file"
grep -Fqx 'disk_format=qcow2' "$state_file"
grep -Fqx 'firmware=uefi-ovmf' "$state_file"
grep -Fqx 'device_model=virtio' "$state_file"
grep -Fqx 'display=spice' "$state_file"
grep -Fq 'dnf install -y edk2-ovmf libvirt-client' "$command_log"
if grep -E '^sudo dnf install .*qemu-guest-agent' "$command_log"; then
  printf 'VM host must not install the guest-only qemu-guest-agent package.\n' >&2
  exit 1
fi
grep -Fq 'systemctl enable --now libvirtd.service' "$command_log"
grep -Fq 'virsh -c qemu:///system net-autostart default' "$command_log"
grep -Fq 'virsh -c qemu:///system pool-autostart default' "$command_log"
grep -Fq 'virt-host-validate qemu' "$command_log"
if grep -Eiq 'bridge|brctl|nmcli.*bridge' "$command_log"; then
  exit 1
fi

verification_output="$("${test_environment[@]}" \
  "$repo_root/scripts/verify-vm-host.sh" --smoke-test 2>&1)"
grep -Fq 'devices-cgroup warning is advisory' <<<"$verification_output"
grep -Fq 'secure-guest warning is advisory' <<<"$verification_output"
grep -Fq -- '--dry-run --print-xml' "$command_log"
grep -Fq -- '--channel=unix,target_type=virtio,name=org.qemu.guest_agent.0' \
  "$command_log"
grep -Fq -- '--channel=spicevmc' "$command_log"

printf 'VM-host package, service, validation, smoke-test, and idempotency tests passed.\n'
