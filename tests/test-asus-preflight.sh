#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
mkdir -p "$test_root/xdg"

test_stub_init "$test_root"
test_stub_install "$test_root" dnf
test_stub_install "$test_root" sudo
test_stub_allow "$test_root" sudo -n -v

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/mokutil" <<'EOF'
#!/usr/bin/env bash
printf 'SecureBoot %s\n' "${MOCK_SECURE_BOOT:-enabled}"
EOF
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -u) printf '1000\n' ;; -un) printf 'fedora-test\n' ;; *) /usr/bin/id "$@" ;; esac
EOF
chmod +x "$mock_bin"/*

printf 'ID=fedora\n' >"$test_root/os-release"

run_preflight() {
  local model="$1"
  local secure_boot="$2"
  local dmi_model="$3"
  shift 3

  local dmi_root="$test_root/dmi-$model-$secure_boot-${dmi_model//\//_}"
  mkdir -p "$dmi_root"
  printf '%s\n' "$dmi_model" >"$dmi_root/board_name"
  printf 'ROG Zephyrus G14\n' >"$dmi_root/product_name"

  env \
    HOME="$test_root/home" \
    XDG_CONFIG_HOME="$test_root/xdg" \
    PATH="$mock_bin:$PATH" \
    OS_RELEASE_FILE="$test_root/os-release" \
    DMI_ROOT="$dmi_root" \
    KERNEL_RELEASE=7.1.0-test \
    MOCK_SECURE_BOOT="$secure_boot" \
    "$repo_root/scripts/install-asus-hardware.sh" \
    --model "$model" --preflight "$@" 2>&1
}

assert_success() {
  local name="$1"
  shift
  local output
  output="$(run_preflight "$@")" || {
    printf 'Expected %s to succeed:\n%s\n' "$name" "$output" >&2
    exit 1
  }
  [[ "$output" == *'preflight passed'* ]]
  printf 'PASS: %s\n' "$name"
}

assert_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$(run_preflight "$@")"; then
    printf 'Expected %s to fail\n' "$name" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf 'Unexpected output from %s:\n%s\n' "$name" "$output" >&2
    exit 1
  }
  printf 'PASS: %s\n' "$name"
}

assert_success "GA402XZ preflight" ga402xz enabled GA402XZ --secure-boot
assert_success "GA402RK preflight" ga402rk disabled GA402RK
assert_failure "Secure Boot fail-fast" "Secure Boot is required but disabled" \
  ga402xz disabled GA402XZ --secure-boot
assert_failure "DMI mismatch fail-fast" "Selected ga402rk, but DMI reports" \
  ga402rk enabled GA402XZ

assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/xdg/dotfiles/hardware.conf" ]]

# Exercise the same failures through the top-level installer. If preflight
# ordering regresses, the base install will reach sudo and populate the log.
run_installer_failure() {
  local expected="$1"
  local model="$2"
  local secure_boot="$3"
  local dmi_model="$4"

  printf '%s\n' "$dmi_model" >"$test_root/top-level-dmi/board_name"
  : >"$test_root/logs/dnf.log"

  local output
  if output="$(
    env \
      HOME="$test_root/home" \
      XDG_CONFIG_HOME="$test_root/xdg" \
      PATH="$mock_bin:$PATH" \
      OS_RELEASE_FILE="$test_root/os-release" \
      DMI_ROOT="$test_root/top-level-dmi" \
      KERNEL_RELEASE=7.1.0-test \
      MOCK_SECURE_BOOT="$secure_boot" \
      "$repo_root/install.sh" --non-interactive --hardware "$model" \
      --secure-boot 2>&1
  )"; then
    printf 'Expected top-level installer to fail preflight\n' >&2
    exit 1
  fi

  [[ "$output" == *"$expected"* ]]
  assert_file_empty "$test_root/logs/dnf.log"
}

mkdir -p "$test_root/top-level-dmi"
run_installer_failure \
  "Secure Boot is required but disabled" ga402xz disabled GA402XZ
run_installer_failure \
  "Selected ga402rk, but DMI reports" ga402rk enabled GA402XZ
printf 'PASS: top-level hardware failures occur before base installation\n'

printf 'ASUS preflight tests passed without mutations.\n'
