#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

test_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "$test_root"
}

trap cleanup EXIT

test_home="$test_root/home"
test_config="$test_root/config"
test_data="$test_root/data"
test_cache="$test_root/cache"
guard_dir="$test_root/guard-bin"

mkdir -p "$test_home" "$test_config" "$test_data" "$test_cache" "$guard_dir"

cat >"$guard_dir/mutation-guard" <<'EOF'
#!/usr/bin/env bash
printf 'Blocked mutating command during installer test: %s\n' "${0##*/}" >&2
exit 97
EOF
chmod +x "$guard_dir/mutation-guard"

mutating_commands=(
  akmods
  asusctl
  chmod
  cp
  curl
  dnf
  git
  install
  kmodgenca
  mise
  mkdir
  mokutil
  mv
  reboot
  rm
  rpm
  stow
  sudo
  systemctl
  tee
  touch
)

for command_name in "${mutating_commands[@]}"; do
  ln -s mutation-guard "$guard_dir/$command_name"
done

test_environment=(
  env
  "HOME=$test_home"
  "XDG_CONFIG_HOME=$test_config"
  "XDG_DATA_HOME=$test_data"
  "XDG_CACHE_HOME=$test_cache"
  "PATH=$guard_dir:$PATH"
)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_output_contains() {
  local case_name="$1"
  local output="$2"
  local fragment="$3"

  if [[ "$output" != *"$fragment"* ]]; then
    printf 'Output from %s did not contain: %s\n' "$case_name" "$fragment" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

run_success() {
  local case_name="$1"
  shift

  local -a expected_fragments=()
  while [[ "$1" != "--" ]]; do
    expected_fragments+=("$1")
    shift
  done
  shift

  local output
  if ! output="$("${test_environment[@]}" "$@" 2>&1)"; then
    printf 'Expected success from %s:\n%s\n' "$case_name" "$output" >&2
    exit 1
  fi

  local fragment
  for fragment in "${expected_fragments[@]}"; do
    assert_output_contains "$case_name" "$output" "$fragment"
  done

  printf 'PASS: %s\n' "$case_name"
}

run_failure() {
  local case_name="$1"
  local expected_fragment="$2"
  shift 2

  local output
  if output="$("${test_environment[@]}" "$@" 2>&1)"; then
    printf 'Expected failure from %s, but it succeeded:\n%s\n' \
      "$case_name" "$output" >&2
    exit 1
  fi

  assert_output_contains "$case_name" "$output" "$expected_fragment"
  printf 'PASS: %s\n' "$case_name"
}

run_failure \
  "mutation guard" \
  "Blocked mutating command during installer test: dnf" \
  dnf install forbidden-package

run_success \
  "default dry-run" \
  "Catppuccin flavour:  macchiato" \
  "ASUS hardware:       disabled" \
  "No changes were made." \
  -- ./install.sh --dry-run

run_success \
  "KDE and LaTeX dry-run" \
  "Catppuccin flavour:  latte" \
  "KDE integration:     true" \
  "LaTeX toolchain:     true" \
  "No changes were made." \
  -- ./install.sh --dry-run --theme latte --kde --latex

run_success \
  "GA402XZ dry-run" \
  "ASUS hardware:       ga402xz" \
  "Require Secure Boot: true" \
  "Battery limit:       80" \
  "No changes were made." \
  -- ./install.sh --dry-run --hardware ga402xz --secure-boot \
  --charge-limit 80

run_success \
  "GA402RK dry-run" \
  "ASUS hardware:       ga402rk" \
  "Require Secure Boot: false" \
  "Battery limit:       unchanged" \
  "No changes were made." \
  -- ./install.sh --dry-run --hardware ga402rk --no-kde

run_success \
  "GA402XZ component dry-run" \
  "Model profile:          ga402xz" \
  "Require Secure Boot:    true" \
  "Battery charge limit:   80" \
  "No changes were made." \
  -- ./scripts/install-asus-hardware.sh --dry-run --model ga402xz \
  --secure-boot --charge-limit 80

run_success \
  "GA402RK component dry-run" \
  "Model profile:          ga402rk" \
  "Graphics:               AMD iGPU + AMD dGPU" \
  "No changes were made." \
  -- ./scripts/install-asus-hardware.sh --dry-run --model ga402rk

run_failure \
  "unknown top-level option" \
  "Unknown option: --invalid-option" \
  ./install.sh --invalid-option

run_failure \
  "missing theme value" \
  "--theme requires a value" \
  ./install.sh --theme

run_failure \
  "invalid theme" \
  "Invalid Catppuccin flavour: espresso" \
  ./install.sh --dry-run --theme espresso

run_failure \
  "missing hardware value" \
  "--hardware requires a value" \
  ./install.sh --hardware

run_failure \
  "invalid hardware profile" \
  "Invalid hardware profile: unknown" \
  ./install.sh --dry-run --hardware unknown

run_failure \
  "Secure Boot without hardware" \
  "--secure-boot requires --hardware" \
  ./install.sh --dry-run --secure-boot

run_failure \
  "charge limit without hardware" \
  "--charge-limit requires --hardware" \
  ./install.sh --dry-run --charge-limit 80

run_failure \
  "out-of-range charge limit" \
  "--charge-limit must be an integer from 40 to 100" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 101

run_failure \
  "invalid component model" \
  "Unsupported ASUS hardware model: unknown" \
  ./scripts/install-asus-hardware.sh --dry-run --model unknown

run_failure \
  "missing component model" \
  "--model is required (ga402xz or ga402rk)" \
  ./scripts/install-asus-hardware.sh --dry-run

if find "$test_home" "$test_config" "$test_data" "$test_cache" \
  -mindepth 1 -print -quit | grep -q .; then
  fail "dry-runs wrote to the isolated home or XDG directories"
fi

printf 'Installer validation passed without host mutations.\n'
