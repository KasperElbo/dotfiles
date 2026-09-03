#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fedora.sh"
# shellcheck source=lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/secure-boot.sh"

model=""
charge_limit=""
require_secure_boot="false"
interactive="true"
dry_run="false"
preflight_only="false"

usage() {
  cat <<'EOF'
Usage: ./scripts/install-asus-hardware.sh --model MODEL [options]

Models:
  ga402xz            ROG Zephyrus G14 2023, AMD iGPU + NVIDIA dGPU
  ga402rk            ROG Zephyrus G14 2022, AMD iGPU + AMD dGPU

Options:
  --charge-limit N   Set the battery charge limit (40-100 percent)
  --secure-boot      Require and verify that Secure Boot is enabled
  --preflight        Validate the machine without making changes
  --dry-run          Show the hardware installation plan only
  --non-interactive  Do not initiate interactive MOK enrollment
  -h, --help         Show this help

Secure Boot firmware settings and reboots are never changed automatically.
EOF
}

while (($#)); do
  case "$1" in
  --model)
    [[ $# -ge 2 ]] || die "--model requires a value"
    model="$2"
    shift 2
    ;;

  --charge-limit)
    [[ $# -ge 2 ]] || die "--charge-limit requires a value"
    charge_limit="$2"
    shift 2
    ;;

  --secure-boot)
    require_secure_boot="true"
    shift
    ;;

  --preflight)
    preflight_only="true"
    interactive="false"
    shift
    ;;

  --dry-run)
    dry_run="true"
    interactive="false"
    shift
    ;;

  --non-interactive)
    interactive="false"
    shift
    ;;

  -h | --help)
    usage
    exit 0
    ;;

  *)
    die "Unknown option: $1"
    ;;
  esac
done

case "$model" in
ga402xz | ga402rk)
  ;;
"")
  die "--model is required (ga402xz or ga402rk)"
  ;;
*)
  die "Unsupported ASUS hardware model: $model"
  ;;
esac

if [[ -n "$charge_limit" ]]; then
  if [[ ! "$charge_limit" =~ ^[0-9]+$ ]] ||
    ((charge_limit < 40 || charge_limit > 100)); then
    die "--charge-limit must be an integer from 40 to 100"
  fi
fi

model_label=""
graphics_label=""

case "$model" in
ga402xz)
  model_label="ROG Zephyrus G14 GA402XZ"
  graphics_label="AMD iGPU + NVIDIA dGPU (RPM Fusion akmod)"
  ;;
ga402rk)
  model_label="ROG Zephyrus G14 GA402RK"
  graphics_label="AMD iGPU + AMD dGPU (kernel/Mesa)"
  ;;
esac

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

ASUS hardware installation plan
-------------------------------

Model profile:          $model ($model_label)
Graphics:               $graphics_label
Require Secure Boot:    $require_secure_boot
Battery charge limit:   ${charge_limit:-unchanged}

Shared steps:
  1. Verify Fedora, kernel version, and the DMI board name.
  2. Enable Terra and install asusctl plus ROG Control Center.
  3. Enable asusd and asus-shutdown.
  4. Let asusd own power profiles by disabling active PPD/Tuned services.
EOF

  step=5

  if [[ "$model" == "ga402xz" ]]; then
    cat <<EOF
  $step. Enable RPM Fusion and install the NVIDIA akmod/CUDA packages.
  $((step + 1)). When Secure Boot is enabled, prepare and enroll the akmods MOK.
  $((step + 2)). Build and verify the NVIDIA kernel module.
EOF
    step=$((step + 3))
  else
    cat <<EOF
  $step. Ensure Fedora AMD firmware and Mesa graphics packages are installed.
  $((step + 1)). Verify that both AMD GPUs use the in-kernel amdgpu driver.
EOF
    step=$((step + 2))
  fi

  if [[ "$require_secure_boot" == "true" ]]; then
    cat <<EOF
  $step. Require Secure Boot to be enabled; firmware changes remain manual.
EOF
    step=$((step + 1))
  fi

  if [[ -n "$charge_limit" ]]; then
    cat <<EOF
  $step. Set and verify the battery charge limit at ${charge_limit}%.
EOF
  fi

  cat <<'EOF'

GPU/MUX modes, firmware updates, and reboots are not changed automatically.
No changes were made.

EOF
  exit 0
fi

require_fedora

kernel_release="${KERNEL_RELEASE:-$(uname -r)}"
kernel_version="${kernel_release%%-*}"
minimum_kernel="7.1"

if [[ "$(printf '%s\n' "$minimum_kernel" "$kernel_version" | sort -V | head -n1)" != \
  "$minimum_kernel" ]]; then
  die "Kernel $minimum_kernel or newer is required; running $kernel_release"
fi

dmi_root="${DMI_ROOT:-/sys/class/dmi/id}"
board_name="$(tr -d '\n' <"$dmi_root/board_name" 2>/dev/null || true)"
product_name="$(tr -d '\n' <"$dmi_root/product_name" 2>/dev/null || true)"
dmi_identity="${board_name} ${product_name}"

if [[ "${dmi_identity^^}" != *"${model^^}"* ]]; then
  die "Selected $model, but DMI reports: ${dmi_identity:-unknown hardware}"
fi

info "Validated hardware: $dmi_identity"

secure_boot="$(secure_boot_state)"

case "$secure_boot" in
enabled)
  info "Secure Boot is enabled"
  ;;
disabled)
  if [[ "$require_secure_boot" == "true" ]]; then
    die "Secure Boot is required but disabled. Enable it in UEFI and rerun the installer."
  fi

  info "Secure Boot is disabled; preserving the current firmware setting"
  ;;
unknown)
  if [[ "$require_secure_boot" == "true" ]]; then
    die "Secure Boot state could not be determined. Check it with 'mokutil --sb-state' before continuing."
  fi

  warn "Secure Boot state could not be determined; continuing because it was not required"
  ;;
esac

if [[ "$preflight_only" == "true" ]]; then
  success "ASUS hardware preflight passed for $model_label"
  exit 0
fi

common_packages=(
  asusctl
  asusctl-rog-gui
  fwupd
  mokutil
  pciutils
)

ensure_terra_repository

info "Installing ASUS hardware support"
sudo dnf install -y "${common_packages[@]}"

info "Enabling ASUS services"
sudo systemctl enable --now asusd.service

if systemctl cat asus-shutdown.service >/dev/null 2>&1; then
  sudo systemctl enable --now asus-shutdown.service
else
  warn "asus-shutdown.service is not provided by the installed package"
fi

for conflicting_unit in \
  power-profiles-daemon.service \
  tuned-ppd.service \
  tuned.service; do
  if systemctl cat "$conflicting_unit" >/dev/null 2>&1 &&
    { systemctl is-active --quiet "$conflicting_unit" ||
      systemctl is-enabled --quiet "$conflicting_unit"; }; then
    info "Disabling conflicting power-profile service: $conflicting_unit"
    sudo systemctl disable --now "$conflicting_unit"
  fi
done

if [[ "$secure_boot" == "unknown" ]]; then
  secure_boot="$(secure_boot_state)"
fi

reboot_recommended="false"
mok_enrollment_pending="false"
mok_enrollment_required="false"

if [[ "$model" == "ga402xz" ]]; then
  ensure_rpm_fusion_repositories

  if [[ "$secure_boot" == "enabled" ]]; then
    info "Preparing akmods signing for Secure Boot"
    sudo dnf install -y kmodtool akmods mokutil openssl
    sudo kmodgenca -a

    mok_certificate="${MOK_CERTIFICATE:-/etc/pki/akmods/certs/public_key.der}"

    if mokutil --test-key "$mok_certificate" >/dev/null 2>&1; then
      info "The akmods signing certificate is already enrolled"
    elif [[ "$interactive" == "true" ]]; then
      mok_enrollment_required="true"
      warn "MOK enrollment requires a temporary password and confirmation after reboot"

      if confirm "Initiate MOK enrollment now?" "y"; then
        sudo mokutil --import "$mok_certificate"
        mok_enrollment_pending="true"
        reboot_recommended="true"
      else
        warn "MOK enrollment skipped; NVIDIA will not load under Secure Boot"
      fi
    else
      mok_enrollment_required="true"
      reboot_recommended="true"
      warn "The akmods signing certificate is not enrolled"
      warn "Run: sudo mokutil --import $mok_certificate"
    fi
  fi

  info "Installing the NVIDIA driver from RPM Fusion"
  sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda

  info "Building the NVIDIA kernel module"
  sudo akmods --force

  if modinfo nvidia >/dev/null 2>&1; then
    success "NVIDIA kernel module is available"
  else
    die "The NVIDIA kernel module was not built for the running kernel"
  fi

  reboot_recommended="true"
else
  amd_packages=(
    amd-gpu-firmware
    mesa-dri-drivers
    mesa-va-drivers
    mesa-vulkan-drivers
  )

  info "Ensuring the Fedora AMD graphics stack is installed"
  sudo dnf install -y "${amd_packages[@]}"
fi

if ! asusctl armoury list; then
  warn "Unable to query ASUS Armoury capabilities before reboot"
fi

if [[ -n "$charge_limit" ]]; then
  info "Setting battery charge limit to ${charge_limit}%"
  asusctl battery limit "$charge_limit"
  asusctl battery info
fi

state_dir="$XDG_CONFIG_HOME/dotfiles"
state_file="$state_dir/hardware.conf"
ensure_dir "$state_dir"

state_temp="$(mktemp "$state_dir/.hardware.XXXXXX")"
{
  printf 'profile=%s\n' "$model"
  printf 'secure_boot=%s\n' "$require_secure_boot"
  printf 'charge_limit=%s\n' "$charge_limit"
} >"$state_temp"
chmod 600 "$state_temp"
mv -- "$state_temp" "$state_file"

success "ASUS hardware support installed for $model_label"

if [[ "$mok_enrollment_pending" == "true" ]]; then
  warn "On reboot, choose Enroll MOK and enter the temporary password"
elif [[ "$mok_enrollment_required" == "true" ]]; then
  warn "Import the MOK certificate before rebooting if NVIDIA should load under Secure Boot"
fi

if [[ "$reboot_recommended" == "true" ]]; then
  warn "Reboot before relying on the NVIDIA driver, then run scripts/verify.sh"
fi
