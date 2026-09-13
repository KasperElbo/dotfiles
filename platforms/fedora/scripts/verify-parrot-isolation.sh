#!/usr/bin/env bash
set -euo pipefail

# This is a host-side verifier. The domain selector is mandatory because a
# guest cannot prove which libvirt definition or forwarding policy owns it.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
libvirt_uri="qemu:///system"
domain=""
network="default"
pool="default"

usage() {
  cat <<'EOF'
Usage: verify-parrot-isolation.sh --domain NAME [options]

Options:
  --domain NAME     Exact libvirt domain to inspect (required)
  --network NAME    Expected NAT network (default: default)
  --pool NAME       Expected file-backed storage pool (default: default)
  --connect URI     Libvirt connection URI (default: qemu:///system)
EOF
}

while (($#)); do
  case "$1" in
  --domain | --network | --pool | --connect)
    [[ $# -ge 2 ]] || { printf 'ERROR: %s requires a value\n' "$1" >&2; exit 2; }
    case "$1" in
    --domain) domain="$2" ;;
    --network) network="$2" ;;
    --pool) pool="$2" ;;
    --connect) libvirt_uri="$2" ;;
    esac
    shift 2
    ;;
  -h | --help) usage; exit 0 ;;
  *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$domain" ]] || { printf 'ERROR: --domain is required\n' >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { printf 'ERROR: virsh is required\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'ERROR: python3 is required\n' >&2; exit 1; }

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
domain_xml="$work_dir/domain.xml"
network_xml="$work_dir/network.xml"
pool_xml="$work_dir/pool.xml"

virsh --connect "$libvirt_uri" dominfo "$domain" >/dev/null
virsh --connect "$libvirt_uri" dumpxml --inactive "$domain" >"$domain_xml"
virsh --connect "$libvirt_uri" net-dumpxml "$network" >"$network_xml"
virsh --connect "$libvirt_uri" pool-dumpxml "$pool" >"$pool_xml"

exec python3 "$repo_root/platforms/fedora/scripts/verify-parrot-isolation.py" \
  --domain "$domain" --network "$network" --pool "$pool" \
  --domain-xml "$domain_xml" --network-xml "$network_xml" --pool-xml "$pool_xml"
