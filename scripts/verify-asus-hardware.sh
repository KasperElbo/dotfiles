#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secure-boot.sh"

failures=0
warnings=0

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

read_state_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' \
    "$state_file"
}

state_file="$XDG_CONFIG_HOME/dotfiles/hardware.conf"

if [[ ! -f "$state_file" ]]; then
  fail "Hardware profile state is missing: $state_file"
  exit 1
fi

model="$(read_state_value profile)"
require_secure_boot="$(read_state_value secure_boot)"
charge_limit="$(read_state_value charge_limit)"

case "$model" in
ga402xz | ga402rk)
  pass "Configured hardware profile: $model"
  ;;
*)
  fail "Invalid hardware profile in $state_file: ${model:-empty}"
  exit 1
  ;;
esac

dmi_root="${DMI_ROOT:-/sys/class/dmi/id}"
board_name="$(tr -d '\n' <"$dmi_root/board_name" 2>/dev/null || true)"
product_name="$(tr -d '\n' <"$dmi_root/product_name" 2>/dev/null || true)"
dmi_identity="${board_name} ${product_name}"

if [[ "${dmi_identity^^}" == *"${model^^}"* ]]; then
  pass "DMI matches $model: $dmi_identity"
else
  fail "DMI does not match $model: ${dmi_identity:-unknown hardware}"
fi

for package in asusctl asusctl-rog-gui; do
  if rpm -q "$package" >/dev/null 2>&1; then
    pass "Package installed: $package"
  else
    fail "Package missing: $package"
  fi
done

if systemctl is-active --quiet asusd.service; then
  pass "asusd.service is active"
else
  fail "asusd.service is not active"
fi

if systemctl is-enabled --quiet asus-shutdown.service; then
  pass "asus-shutdown.service is enabled"
else
  warning "asus-shutdown.service is not enabled"
fi

for conflicting_unit in \
  power-profiles-daemon.service \
  tuned-ppd.service \
  tuned.service; do
  if systemctl is-active --quiet "$conflicting_unit" ||
    systemctl is-enabled --quiet "$conflicting_unit"; then
    fail "Conflicting power-profile service is active or enabled: $conflicting_unit"
  else
    pass "Power-profile service is not active: $conflicting_unit"
  fi
done

if asusctl armoury list >/dev/null 2>&1; then
  pass "ASUS Armoury capabilities are available"
else
  fail "ASUS Armoury capabilities could not be queried"
fi

secure_boot="$(secure_boot_state)"

if [[ "$secure_boot" == "enabled" ]]; then
  pass "Secure Boot is enabled"
elif [[ "$require_secure_boot" == "true" ]]; then
  fail "Secure Boot is required but ${secure_boot}"
elif [[ "$secure_boot" == "disabled" ]]; then
  warning "Secure Boot is not enabled"
else
  warning "Secure Boot state could not be determined"
fi

pci_output="$(lspci -k 2>/dev/null || true)"

if [[ "$model" == "ga402xz" ]]; then
  for package in akmod-nvidia xorg-x11-drv-nvidia-cuda; do
    if rpm -q "$package" >/dev/null 2>&1; then
      pass "Package installed: $package"
    else
      fail "Package missing: $package"
    fi
  done

  if grep -qi 'NVIDIA' <<<"$pci_output"; then
    pass "NVIDIA dGPU detected"
  else
    warning "NVIDIA dGPU not detected; it may be disabled in ASUS Armoury"
  fi

  if modinfo nvidia >/dev/null 2>&1; then
    pass "NVIDIA kernel module is available"
  else
    fail "NVIDIA kernel module is unavailable"
  fi

  if [[ "$secure_boot" == "enabled" ]]; then
    mok_certificate="${MOK_CERTIFICATE:-/etc/pki/akmods/certs/public_key.der}"

    if [[ ! -f "$mok_certificate" ]]; then
      fail "akmods signing certificate is missing"
    else
      probe_mok_key "$mok_certificate"

      case "$MOK_KEY_STATE" in
      enrolled)
        pass "akmods signing certificate is enrolled"
        ;;
      pending)
        fail "akmods signing certificate is pending MOK enrollment"
        ;;
      not-enrolled)
        fail "akmods signing certificate is not enrolled"
        ;;
      blocked)
        fail "akmods signing certificate is blocked"
        ;;
      unknown)
        warning "mokutil returned status $MOK_KEY_STATUS: ${MOK_KEY_OUTPUT:-no diagnostic output}"
        fail "akmods signing certificate state could not be determined"
        ;;
      esac
    fi
  fi

  if nvidia-smi >/dev/null 2>&1; then
    pass "NVIDIA driver is operational"
  else
    warning "nvidia-smi is unavailable; reboot or enable the dGPU if needed"
  fi
else
  for package in \
    amd-gpu-firmware \
    mesa-dri-drivers \
    mesa-va-drivers \
    mesa-vulkan-drivers; do
    if rpm -q "$package" >/dev/null 2>&1; then
      pass "Package installed: $package"
    else
      fail "Package missing: $package"
    fi
  done

  amd_gpu_count="$(
    grep -Ei 'VGA compatible controller|3D controller|Display controller' \
      <<<"$pci_output" | grep -Eci 'AMD|ATI' || true
  )"

  if ((amd_gpu_count >= 2)); then
    pass "Both AMD GPUs are detected"
  else
    warning "Expected two AMD GPUs, found $amd_gpu_count; the dGPU may be disabled"
  fi

  amdgpu_driver_count="$(grep -ci 'Kernel driver in use: amdgpu' <<<"$pci_output" || true)"

  if ((amdgpu_driver_count >= 2)); then
    pass "Both AMD GPUs use the amdgpu kernel driver"
  else
    warning "Found $amdgpu_driver_count active amdgpu device(s)"
  fi
fi

if [[ -n "$charge_limit" ]]; then
  battery_info="$(asusctl battery info 2>/dev/null || true)"

  if grep -Eq "${charge_limit}%" <<<"$battery_info"; then
    pass "Battery charge limit is ${charge_limit}%"
  else
    fail "Battery charge limit is not ${charge_limit}%"
  fi
fi

printf '\n'

if ((failures > 0)); then
  printf '\033[1;31mHardware verification failed:\033[0m %d failure(s), %d warning(s)\n' \
    "$failures" "$warnings"
  exit 1
fi

if ((warnings > 0)); then
  printf '\033[1;33mHardware verification passed with warnings:\033[0m %d warning(s)\n' \
    "$warnings"
else
  printf '\033[1;32mHardware verification passed.\033[0m\n'
fi
