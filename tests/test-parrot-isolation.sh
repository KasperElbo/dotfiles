#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/platforms/fedora/scripts/verify-parrot-isolation.py"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

cat >"$test_root/network.xml" <<'EOF'
<network><name>default</name><forward mode="nat"/></network>
EOF
cat >"$test_root/bridge.xml" <<'EOF'
<network><name>bridge</name><forward mode="bridge"/></network>
EOF
cat >"$test_root/pool.xml" <<'EOF'
<pool type="dir"><name>default</name><target><path>/var/lib/libvirt/images</path></target></pool>
EOF

write_domain() {
  local extra="$1"
  cat >"$test_root/domain.xml" <<EOF
<domain type="kvm">
  <name>parrot-ctf</name>
  <devices>
    <disk type="file" device="disk"><source file="/var/lib/libvirt/images/parrot-ctf.qcow2"/></disk>
    <interface type="network"><source network="default"/></interface>
    <channel type="unix"><target type="virtio" name="org.qemu.guest_agent.0"/></channel>
    <channel type="spicevmc"><target type="virtio" name="com.redhat.spice.0"/></channel>
    $extra
  </devices>
</domain>
EOF
}

run_verifier() {
  python3 "$verifier" \
    --domain parrot-ctf --network default --pool default \
    --domain-xml "$test_root/domain.xml" \
    --network-xml "${1:-$test_root/network.xml}" \
    --pool-xml "$test_root/pool.xml"
}

write_domain ""
positive="$(run_verifier)"
grep -Fq 'VERIFIED' <<<"$positive"
grep -Fq 'network forwarding mode: NAT (default)' <<<"$positive"
grep -Fq 'NOT OBSERVED' <<<"$positive"
grep -Fq 'filesystem passthrough devices' <<<"$positive"
grep -Fq 'MANUAL ASSURANCE REQUIRED' <<<"$positive"

write_domain '<interface type="bridge"><source bridge="br0"/></interface>'
if run_verifier >"$test_root/bridged.log" 2>&1; then
  printf 'Bridged networking passed the NAT-only policy.\n' >&2
  exit 1
fi
grep -Fq 'non-policy interface: type=bridge' "$test_root/bridged.log"

write_domain '<filesystem type="mount"><driver type="virtiofs"/><source dir="/home/user"/><target dir="host"/></filesystem>'
if run_verifier >"$test_root/filesystem.log" 2>&1; then
  printf 'Filesystem passthrough passed the isolation policy.\n' >&2
  exit 1
fi
grep -Fq 'filesystem passthrough present' "$test_root/filesystem.log"

write_domain '<channel type="unix"><source mode="bind" path="/run/user/1000/ssh-auth.sock"/><target type="virtio" name="org.example.ssh-agent"/></channel>'
if run_verifier >"$test_root/agent.log" 2>&1; then
  printf 'Forwarded SSH agent passed the isolation policy.\n' >&2
  exit 1
fi
grep -Fq 'possible forwarded host agent channel' "$test_root/agent.log"

write_domain '<hostdev mode="subsystem" type="usb"><source><vendor id="0x1234"/></source></hostdev>'
if run_verifier >"$test_root/hostdev.log" 2>&1; then
  printf 'Host-device passthrough passed the isolation policy.\n' >&2
  exit 1
fi
grep -Fq 'host USB/PCI/device passthrough present' "$test_root/hostdev.log"

write_domain ""
if run_verifier "$test_root/bridge.xml" >"$test_root/network-mode.log" 2>&1; then
  printf 'Bridge forwarding mode passed the NAT-only policy.\n' >&2
  exit 1
fi
grep -Fq 'network forwarding mode is bridge, expected nat' "$test_root/network-mode.log"

printf 'Parrot host isolation policy tests passed.\n'
