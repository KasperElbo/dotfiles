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

if [[ "$*" == "-q supergfxctl" ]]; then
  [[ "${MOCK_SUPERGFXCTL_INSTALLED:-false}" == true ]]
  exit
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
    MOCK_SUPERGFXCTL_INSTALLED="${2:-false}" \
    "$repo_root/platforms/fedora/scripts/verify-asus-hardware.sh" 2>&1
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
[[ "$output" == *"supergfxctl is not installed"* ]]
printf 'PASS: Mesa VA-API capability accepts an installed virtual provider\n'
printf 'PASS: supported ASUS profile verifies supergfxctl is absent\n'

if output="$(run_verification)"; then
  printf 'Expected verification without a Mesa VA-API provider to fail\n' >&2
  exit 1
fi

[[ "$output" == *"RPM capability missing: mesa-va-drivers"* ]]
printf 'PASS: missing Mesa VA-API capability fails verification\n'

if output="$(run_verification "$provider" true)"; then
  printf 'Expected verification with supergfxctl installed to fail\n' >&2
  exit 1
fi

[[ "$output" == *"supergfxctl must not be installed for the supported ASUS hardware profile"* ]]
printf 'PASS: installed supergfxctl fails ASUS hardware verification\n'
# ---------------------------------------------------------------------------
# The ga402xz profile: MOK enrollment and the battery charge limit
# ---------------------------------------------------------------------------
#
# The fixture above records secure_boot=false and an empty charge_limit, so
# neither the akmods MOK checks nor the charge-limit check was ever reached by
# any suite. Both are covered here, on the machine they exist for.

xz_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root" "$xz_root"' EXIT

xz_bin="$xz_root/bin"
mkdir -p \
  "$xz_bin" \
  "$xz_root/xdg/dotfiles" \
  "$xz_root/dmi" \
  "$xz_root/power-supply/BAT0" \
  "$xz_root/logs"

cat >"$xz_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-q supergfxctl" ]]; then
  exit 1
fi

case "$*" in
  "-q asusctl" | \
    "-q asusctl-rog-gui" | \
    "-q akmod-nvidia" | \
    "-q xorg-x11-drv-nvidia-cuda") exit 0 ;;
esac

exit 1
EOF
cat >"$xz_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet asusd.service" | \
    "is-enabled --quiet asus-shutdown.service") exit 0 ;;
  "is-enabled "*) printf 'not-found\n'; exit 1 ;;
esac

exit 1
EOF
cat >"$xz_bin/asusctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "armoury list" ]]
EOF
cat >"$xz_bin/lspci" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
01:00.0 VGA compatible controller: NVIDIA Corporation GA107M [GeForce RTX 3050 Ti]
	Kernel driver in use: nvidia
OUTPUT
EOF
cat >"$xz_bin/modinfo" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "nvidia" ]]
EOF
cat >"$xz_bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# mokutil answers --sb-state unprivileged; --test-key is the privileged probe
# and refuses to say anything useful unless sudo ran it, the way the real one
# refuses to read MokListRT as an ordinary user.
cat >"$xz_bin/mokutil" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--sb-state" ]]; then
  printf 'SecureBoot enabled\n'
  exit 0
fi

if [[ "$1" == "--test-key" ]]; then
  if [[ "${MOCK_PRIVILEGED:-false}" != "true" ]]; then
    printf 'Failed to read MokListRT: Permission denied\n' >&2
    exit 13
  fi

  printf '%s\n' "${MOCK_MOK_OUTPUT:-$2 is already enrolled}"
  exit "${MOCK_MOK_STATUS:-0}"
fi

exit 1
EOF

# A sudo that refuses -n the way sudo does when the timestamp has expired,
# rather than one the verifier can ask whether it is authorized. Every
# invocation is logged so the suite can assert what the verifier asked for
# instead of trusting that it asked politely.
cat >"$xz_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${MOCK_SUDO_LOG:?MOCK_SUDO_LOG is required}"

non_interactive="false"
if [[ "${1:-}" == "-n" ]]; then
  non_interactive="true"
  shift
fi

if [[ "${MOCK_SUDO_AUTHORIZED:-true}" != "true" ]]; then
  if [[ "$non_interactive" == "true" ]]; then
    printf 'sudo: a password is required\n' >&2
    exit 1
  fi

  # The real sudo would block on a password prompt here. A suite cannot wait
  # for that, so stand in for the hang with a status no caller expects.
  printf 'sudo: FIXTURE WOULD HAVE PROMPTED FOR A PASSWORD\n' >&2
  exit 97
fi

if [[ "${1:-}" == "test" ]]; then
  shift
  test "$@"
  exit
fi

MOCK_PRIVILEGED="true" exec "$@"
EOF
chmod +x "$xz_bin"/*

printf 'GA402XZ\n' >"$xz_root/dmi/board_name"
printf 'ROG Zephyrus G14\n' >"$xz_root/dmi/product_name"
printf '80\n' >"$xz_root/power-supply/BAT0/charge_control_end_threshold"

cat >"$xz_root/xdg/dotfiles/hardware.conf" <<'EOF'
profile=ga402xz
secure_boot=true
charge_limit=80
EOF

mok_certificate="$xz_root/pki/public_key.der"
mkdir -p "$xz_root/pki"
: >"$mok_certificate"

run_xz_verification() {
  : >"$xz_root/logs/sudo.log"
  env \
    XDG_CONFIG_HOME="$xz_root/xdg" \
    PATH="$xz_bin:$PATH" \
    DMI_ROOT="$xz_root/dmi" \
    POWER_SUPPLY_ROOT="$xz_root/power-supply" \
    MOK_CERTIFICATE="$mok_certificate" \
    MOCK_SUDO_LOG="$xz_root/logs/sudo.log" \
    MOCK_SUDO_AUTHORIZED="${MOCK_SUDO_AUTHORIZED:-true}" \
    MOCK_MOK_OUTPUT="${MOCK_MOK_OUTPUT:-}" \
    MOCK_MOK_STATUS="${MOCK_MOK_STATUS:-0}" \
    "$repo_root/platforms/fedora/scripts/verify-asus-hardware.sh" 2>&1
}

# Every sudo the verifier makes must carry -n. This is the assertion that keeps
# a bare sudo from coming back: it reads the log rather than the source, so a
# prompt reintroduced through a helper is caught as well as one written here.
assert_every_sudo_non_interactive() {
  local invocation
  while IFS= read -r invocation; do
    [[ -n "$invocation" ]] || continue
    if [[ "$invocation" != "-n "* ]]; then
      printf 'verifier ran sudo without -n: %s\n' "$invocation" >&2
      exit 1
    fi
  done <"$xz_root/logs/sudo.log"
}

assert_sudo_was_called() {
  if [[ ! -s "$xz_root/logs/sudo.log" ]]; then
    printf 'expected the verifier to have attempted a privileged read\n' >&2
    exit 1
  fi
}

# 1. Authorized, certificate present and enrolled, limit as recorded.
output="$(run_xz_verification)" || {
  printf 'Expected the authorized ga402xz run to succeed:\n%s\n' "$output" >&2
  exit 1
}

[[ "$output" == *"akmods signing certificate is enrolled"* ]]
[[ "$output" == *"Battery charge limit is 80%"* ]]
assert_sudo_was_called
assert_every_sudo_non_interactive
printf 'PASS: authorized ga402xz verification reads the MOK state and the charge limit\n'

# 2. Unauthorized. The run must complete rather than stop on a prompt, and the
#    MOK checks must be reported as unobserved rather than as drift.
MOCK_SUDO_AUTHORIZED="false"
output="$(run_xz_verification)" || {
  printf 'Expected the unauthorized ga402xz run to succeed:\n%s\n' "$output" >&2
  exit 1
}

[[ "$output" == *"needs a sudo password"* ]]
[[ "$output" != *"akmods signing certificate is missing"* ]]
[[ "$output" != *"FIXTURE WOULD HAVE PROMPTED"* ]]
[[ "$output" == *"unobserved check"* ]]
assert_sudo_was_called
assert_every_sudo_non_interactive
printf 'PASS: ga402xz verification without cached sudo reports not observed, not drift\n'

# 3. The same certificate genuinely absent, with sudo able to answer, must
#    still fail. Without this the case above would be satisfied by a verifier
#    that simply stopped looking.
MOCK_SUDO_AUTHORIZED="true"
rm -f "$mok_certificate"

if output="$(run_xz_verification)"; then
  printf 'Expected a missing MOK certificate to fail verification:\n%s\n' \
    "$output" >&2
  exit 1
fi

[[ "$output" == *"akmods signing certificate is missing: $mok_certificate"* ]]
assert_every_sudo_non_interactive
printf 'PASS: an absent MOK certificate is drift when sudo could answer\n'

: >"$mok_certificate"

# 4. GAP-04: the charge level is not the charge limit. A battery held at an 80%
#    limit sits at 80%, which is what made the old search pass on exactly the
#    machines where the limit had been in force.
printf '100\n' >"$xz_root/power-supply/BAT0/charge_control_end_threshold"

if output="$(run_xz_verification)"; then
  printf 'Expected a charge limit of 100%% against a recorded 80%% to fail:\n%s\n' \
    "$output" >&2
  exit 1
fi

[[ "$output" == *"Battery charge limit is 100%, not 80%"* ]]
printf 'PASS: a charge limit that does not match the record fails verification\n'

# 5. No battery exposes the attribute: unobserved, not a pass and not drift.
rm -rf "$xz_root/power-supply"
mkdir -p "$xz_root/power-supply"

output="$(run_xz_verification)" || {
  printf 'Expected a machine with no charge-limit attribute to succeed:\n%s\n' \
    "$output" >&2
  exit 1
}

[[ "$output" == *"charge_control_end_threshold"* ]]
[[ "$output" != *"Battery charge limit is 80%"* ]]
printf 'PASS: a missing charge-limit attribute is unobserved rather than a pass\n'
