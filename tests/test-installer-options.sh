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

for command_name in akmods asusctl curl dnf kmodgenca mise mokutil opam \
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
run_success "default login shell dry-run" \
  "Set Zsh as the user's default login shell." \
  ./install.sh --dry-run
run_success "login shell reboot dry-run" \
  "reboot so Plasma and user services refresh SHELL" \
  ./install.sh --dry-run
run_success "optional feature dry-run" "LaTeX toolchain:     true" \
  ./install.sh --dry-run --theme latte --kde --latex
run_success "OCaml remains opt-in" "OCaml profile:       false" \
  ./install.sh --dry-run
run_success "OCaml profile dry-run" "common/install-ocaml.sh" \
  ./install.sh --dry-run --ocaml
run_success "OCaml version override dry-run" "OCaml 5.4.1" \
  env OCAML_COMPILER_VERSION=5.4.1 ./install.sh --dry-run --ocaml
run_success "Sway remains opt-in" "Sway session:        false" \
  ./install.sh --dry-run
run_success "Sway dry-run" "platforms/fedora/scripts/install-sway.sh" \
  ./install.sh --dry-run --sway
run_success "VM-host dry-run" "platforms/fedora/scripts/install-vm-host.sh" \
  ./install.sh --dry-run --vm-host
run_success "VM-host remains opt-in" "VM-host profile:     false" \
  ./install.sh --dry-run
run_success "VM-guest dry-run" "platforms/fedora/scripts/install-vm-guest.sh" \
  ./install.sh --dry-run --vm-guest
run_success "VM-guest remains opt-in" "VM-guest profile:    false" \
  ./install.sh --dry-run
run_success "Hardening dry-run" "platforms/fedora/scripts/install-hardening.sh" \
  ./install.sh --dry-run --hardening
run_success "Hardening remains opt-in" "Hardening profile:   false" \
  ./install.sh --dry-run
run_success "Standalone hardening dry-run" \
  "kernel.yama.ptrace_scope=1, kernel.kptr_restrict=2" \
  ./scripts/install-hardening.sh --dry-run
run_success "Desktop tools remains opt-in" "Desktop tools:       false" \
  ./install.sh --dry-run
run_success "Desktop-tools dry-run" \
  "platforms/fedora/scripts/install-desktop-tools.sh" \
  ./install.sh --dry-run --desktop-tools
run_success "Desktop-tools dry-run lists reused KDE baseline apps" \
  "reuses Gwenview, Okular, Ark" \
  ./install.sh --dry-run --desktop-tools
run_success "Desktop-tools force-defaults remains opt-in" \
  "Force app defaults:  false" \
  ./install.sh --dry-run --desktop-tools
run_success "Desktop-tools force-defaults dry-run" \
  "install-desktop-tools.sh --force-defaults" \
  ./install.sh --dry-run --desktop-tools --desktop-tools-force-defaults
run_success "Containers remains opt-in" "Containers profile:  false" \
  ./install.sh --dry-run
run_success "Containers dry-run" \
  "platforms/fedora/scripts/install-containers.sh" \
  ./install.sh --dry-run --containers
run_success "Containers dry-run documents no Docker Engine/alias" \
  "Docker Engine/alias:   not installed" \
  ./scripts/install-containers.sh --dry-run
run_success "Containers API socket remains opt-in" \
  "Containers API socket: false" \
  ./install.sh --dry-run --containers
run_success "Containers API socket dry-run" \
  "install-containers.sh --api-socket" \
  ./install.sh --dry-run --containers --containers-api-socket
run_success "Standalone containers dry-run" \
  "Rootless API socket:   false" \
  ./scripts/install-containers.sh --dry-run
run_success "AI remains opt-in" "AI profile:          false" \
  ./install.sh --dry-run
run_success "AI dry-run" "common/install-ai.sh" \
  ./install.sh --dry-run --ai
run_success "AI Codex remains opt-in" "AI Codex subcomponent: false" \
  ./install.sh --dry-run --ai
run_success "AI Codex dry-run" "common/install-ai.sh --codex" \
  ./install.sh --dry-run --ai --codex
run_success "AI FirstMate remains opt-in" "AI FirstMate subcomponent: false" \
  ./install.sh --dry-run --ai
run_success "AI FirstMate dry-run" "common/install-ai.sh --firstmate" \
  ./install.sh --dry-run --ai --firstmate
run_success "AI Codex and FirstMate together dry-run" \
  "common/install-ai.sh --codex --firstmate" \
  ./install.sh --dry-run --ai --codex --firstmate
run_success "AI GNHF remains opt-in" "AI GNHF subcomponent: false" \
  ./install.sh --dry-run --ai
run_success "AI GNHF dry-run" "common/install-ai.sh --gnhf" \
  ./install.sh --dry-run --ai --gnhf
run_success "AI Codex, FirstMate and GNHF together dry-run" \
  "common/install-ai.sh --codex --firstmate --gnhf" \
  ./install.sh --dry-run --ai --codex --firstmate --gnhf
run_success "Standalone AI dry-run" "Herdr:                installed via mise" \
  ./scripts/install-ai.sh --dry-run
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
run_failure "force-defaults without desktop-tools" \
  "--desktop-tools-force-defaults requires --desktop-tools" \
  ./install.sh --dry-run --desktop-tools-force-defaults
run_failure "containers API socket without containers" \
  "--containers-api-socket requires --containers" \
  ./install.sh --dry-run --containers-api-socket
run_failure "charge limit without hardware" "--charge-limit requires --hardware" \
  ./install.sh --dry-run --charge-limit 80
run_failure "invalid charge limit" \
  "--charge-limit must be an integer from 40 to 100" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 101
run_failure "VM host and guest are mutually exclusive" \
  "--vm-host and --vm-guest cannot be combined" \
  ./install.sh --dry-run --vm-host --vm-guest
run_failure "VM guest excludes laptop hardware" \
  "--vm-guest and --hardware cannot be combined" \
  ./install.sh --dry-run --vm-guest --hardware ga402xz
run_failure "Codex requires the AI profile" "--codex requires --ai" \
  ./install.sh --dry-run --codex
run_failure "FirstMate requires the AI profile" "--firstmate requires --ai" \
  ./install.sh --dry-run --firstmate
run_failure "GNHF requires the AI profile" "--gnhf requires --ai" \
  ./install.sh --dry-run --gnhf

if find "$test_root/home" "$test_root/config" "$test_root/data" \
  "$test_root/cache" -mindepth 1 -print -quit | grep -q .; then
  printf 'Dry-runs changed isolated user state\n' >&2
  exit 1
fi

printf 'Installer option and dry-run tests passed.\n'
