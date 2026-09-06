#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p "$test_root"/{home,config,data,cache,guard-bin}
guard_dir="$test_root/guard-bin"

cat >"$guard_dir/mutation-guard" <<'EOF'
#!/usr/bin/env bash
printf 'Blocked mutating command during installer test: %s\n' "${0##*/}" >&2
exit 97
EOF
chmod +x "$guard_dir/mutation-guard"

for command_name in akmods asusctl curl dnf kmodgenca mise mokutil \
  reboot rpm stow sudo systemctl; do
  ln -s mutation-guard "$guard_dir/$command_name"
done

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/config"
  "XDG_DATA_HOME=$test_root/data"
  "XDG_CACHE_HOME=$test_root/cache"
  "PATH=$guard_dir:$PATH"
)

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

run_success() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  output="$("${test_environment[@]}" "$@" 2>&1)" || {
    printf 'Expected success from %s:\n%s\n' "$name" "$output" >&2
    exit 1
  }
  assert_contains "$output" "$expected"
  printf 'PASS: %s\n' "$name"
}

run_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("${test_environment[@]}" "$@" 2>&1)"; then
    printf 'Expected failure from %s\n' "$name" >&2
    exit 1
  fi
  assert_contains "$output" "$expected"
  printf 'PASS: %s\n' "$name"
}

run_success "default dry-run" "ASUS hardware:       disabled" \
  ./install.sh --dry-run
run_success "optional feature dry-run" "LaTeX toolchain:     true" \
  ./install.sh --dry-run --theme latte --kde --latex
run_success "Sway remains opt-in" "Sway session:        false" \
  ./install.sh --dry-run
run_success "Sway dry-run" "platforms/fedora/scripts/install-sway.sh" \
  ./install.sh --dry-run --sway
run_success "VM-host dry-run" "platforms/fedora/scripts/install-vm-host.sh" \
  ./install.sh --dry-run --vm-host
run_success "VM-host remains opt-in" "VM-host profile:     false" \
  ./install.sh --dry-run
run_success "Sway dry-run forwards local setup" \
  "platforms/fedora/scripts/setup-local.sh macchiato --sway" \
  ./install.sh --dry-run --sway
run_success "GA402XZ Sway dry-run forwards hardware to local setup" \
  "platforms/fedora/scripts/setup-local.sh macchiato --sway --hardware ga402xz" \
  ./install.sh --dry-run --sway --hardware ga402xz
run_success "GA402XZ dry-run" "Require Secure Boot: true" \
  ./install.sh --dry-run --hardware ga402xz --secure-boot --charge-limit 80
run_success "GA402RK dry-run" "Graphics:               AMD iGPU + AMD dGPU" \
  ./scripts/install-asus-hardware.sh --dry-run --model ga402rk

run_failure "unknown option" "Unknown option: --invalid-option" \
  ./install.sh --invalid-option
run_failure "missing theme value" "--theme requires a value" ./install.sh --theme
run_failure "invalid theme" "Invalid Catppuccin flavour: espresso" \
  ./install.sh --dry-run --theme espresso
run_failure "missing hardware value" "--hardware requires a value" \
  ./install.sh --hardware
run_failure "invalid hardware" "Invalid hardware profile: unknown" \
  ./install.sh --dry-run --hardware unknown
run_failure "Secure Boot without hardware" "--secure-boot requires --hardware" \
  ./install.sh --dry-run --secure-boot
run_failure "charge limit without hardware" "--charge-limit requires --hardware" \
  ./install.sh --dry-run --charge-limit 80
run_failure "invalid charge limit" \
  "--charge-limit must be an integer from 40 to 100" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 101

if find "$test_root/home" "$test_root/config" "$test_root/data" \
  "$test_root/cache" -mindepth 1 -print -quit | grep -q .; then
  printf 'Dry-runs changed isolated user state\n' >&2
  exit 1
fi

printf 'Installer option and dry-run tests passed.\n'
