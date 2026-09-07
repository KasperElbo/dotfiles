#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
mkdir -p "$mock_bin" "$test_root/xdg/dotfiles" "$test_root/dmi"

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-q --whatprovides mesa-va-drivers" ]]; then
  if [[ -n "${MOCK_MESA_VA_PROVIDER:-}" ]]; then
    printf '%s\n' "$MOCK_MESA_VA_PROVIDER"
    exit 0
  fi

  exit 1
fi

case "$*" in
  "-q asusctl" | \
    "-q asusctl-rog-gui" | \
    "-q amd-gpu-firmware" | \
    "-q mesa-dri-drivers" | \
    "-q mesa-vulkan-drivers") exit 0 ;;
esac

exit 1
EOF
cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet asusd.service" | \
    "is-enabled --quiet asus-shutdown.service") exit 0 ;;
  "is-enabled "*) printf 'not-found\n'; exit 1 ;;
esac

exit 1
EOF
cat >"$mock_bin/asusctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "armoury list" ]]
EOF
cat >"$mock_bin/mokutil" <<'EOF'
#!/usr/bin/env bash
printf 'SecureBoot disabled\n'
EOF
cat >"$mock_bin/lspci" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt
	Kernel driver in use: amdgpu
04:00.0 Display controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 23
	Kernel driver in use: amdgpu
OUTPUT
EOF
chmod +x "$mock_bin"/*

cat >"$test_root/xdg/dotfiles/hardware.conf" <<'EOF'
profile=ga402rk
secure_boot=false
charge_limit=
EOF
printf 'GA402RK\n' >"$test_root/dmi/board_name"
printf 'ROG Zephyrus G14\n' >"$test_root/dmi/product_name"

run_verification() {
  env \
    XDG_CONFIG_HOME="$test_root/xdg" \
    PATH="$mock_bin:$PATH" \
    DMI_ROOT="$test_root/dmi" \
    MOCK_MESA_VA_PROVIDER="${1:-}" \
    "$repo_root/scripts/verify-asus-hardware.sh" 2>&1
}

provider="mesa-dri-drivers-26.1.8-1.fc44.x86_64"
output="$(run_verification "$provider")" || {
  printf 'Expected verification with a virtual provider to succeed:\n%s\n' \
    "$output" >&2
  exit 1
}

[[ "$output" == *"RPM capability provided: mesa-va-drivers ($provider)"* ]]
[[ "$output" == *"Both AMD GPUs are detected"* ]]
[[ "$output" == *"Both AMD GPUs use the amdgpu kernel driver"* ]]
printf 'PASS: Mesa VA-API capability accepts an installed virtual provider\n'

if output="$(run_verification)"; then
  printf 'Expected verification without a Mesa VA-API provider to fail\n' >&2
  exit 1
fi

[[ "$output" == *"RPM capability missing: mesa-va-drivers"* ]]
printf 'PASS: missing Mesa VA-API capability fails verification\n'
