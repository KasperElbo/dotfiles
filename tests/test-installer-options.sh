#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

guard_dir="$test_root/bin"
test_stub_init "$test_root"
for command_name in curl dnf mise sudo systemctl; do
  test_stub_install "$test_root" "$command_name"
done

cat >"$guard_dir/mutation-guard" <<'EOF'
#!/usr/bin/env bash
printf 'Blocked mutating command during installer test: %s\n' "${0##*/}" >&2
exit 97
EOF
chmod +x "$guard_dir/mutation-guard"

for command_name in akmods asusctl kmodgenca mokutil opam reboot rpm stow; do
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

run_success() {
  local name="$1"
  local expected="$2"
  shift 2
  run_capture "${test_environment[@]}" "$@"
  if ((TEST_STATUS != 0)); then
    _test_die "expected success from $name (status $TEST_STATUS):\n$TEST_OUTPUT"
  fi
  assert_contains "$TEST_OUTPUT" "$expected"
  printf 'PASS: %s\n' "$name"
}

run_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  run_capture "${test_environment[@]}" "$@"
  if ((TEST_STATUS == 0)); then
    _test_die "expected failure from $name"
  fi
  assert_contains "$TEST_OUTPUT" "$expected"
  printf 'PASS: %s\n' "$name"
}

long_help="$("${test_environment[@]}" ./install.sh --help 2>&1)"
short_help="$("${test_environment[@]}" ./install.sh -h 2>&1)"
assert_contains "$long_help" "--platform NAME    Target platform:"
assert_contains "$long_help" "fedora (default)"
assert_eq "$long_help" "$short_help" "./install.sh -h and --help produced different output"
printf 'PASS: -h and --help consistently document platform selection and the default\n'

platforms=()
for platform_installer in platforms/*/install.sh; do
  platforms+=("$(basename -- "$(dirname -- "$platform_installer")")")
done

# The generated option reference is the documented platform selector; it is
# rendered from config/install-options.tsv, so a platform that exists in the
# tree but not in the documentation fails here.
# shellcheck disable=SC2016 # Literal backticks in the Markdown table cell.
documented_platform_selector="$(
  sed -n '/`--platform PLATFORM`/p' docs/reference/installer-options.md
)"
for platform_name in "${platforms[@]}"; do
  assert_contains "$long_help" "$platform_name"
  assert_contains "$documented_platform_selector" "$platform_name"

  platform_help="$(
    "${test_environment[@]}" \
      ./install.sh --platform "$platform_name" --help 2>&1
  )" || {
    printf 'Expected help for platform %s to succeed:\n%s\n' \
      "$platform_name" "$platform_help" >&2
    exit 1
  }
  platform_marker="Options (platform '$platform_name'):"
  assert_contains "$platform_help" "--platform NAME    Target platform:"
  assert_contains "$platform_help" "$platform_marker"
  assert_contains "$platform_help" '--theme FLAVOUR'
  [[ "$(grep -c '^Usage:' <<<"$platform_help")" -eq 1 ]] || {
    printf 'Expected one Usage section for platform %s:\n%s\n' \
      "$platform_name" "$platform_help" >&2
    exit 1
  }
  [[ "$(grep -c '^Options' <<<"$platform_help")" -eq 1 ]] || {
    printf 'Expected one Options section for platform %s:\n%s\n' \
      "$platform_name" "$platform_help" >&2
    exit 1
  }
  printf 'PASS: --platform %s --help combines selector and platform options\n' \
    "$platform_name"
done

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
# --latex has no fixed default: it is asked interactively, so with nobody to
# ask it resolves to disabled. What the machine remembers is that resolved
# value, never the auto the manifest declares.
run_success "LaTeX resolves to disabled when there is nobody to ask" \
  "LaTeX toolchain:     false" \
  ./install.sh --platform fedora --dry-run --non-interactive
run_success "a resolved LaTeX answer is recorded as true or false" \
  "latex:false" \
  ./install.sh --platform fedora --dry-run --non-interactive
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
  ./platforms/fedora/scripts/install-hardening.sh --dry-run
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
run_success "Dictation remains opt-in" "Dictation profile:   false" \
  ./install.sh --dry-run
run_success "Dictation dry-run" \
  "platforms/fedora/scripts/install-dictation.sh" \
  ./install.sh --dry-run --dictation
run_success "Dictation dry-run names the pinned provider" \
  "Handy from a pinned, digest-verified release rpm" \
  ./install.sh --dry-run --dictation
# The dictation capability depends on base alone, so the plan has to name the
# key the desktop in front of this person actually binds. A tracked Sway
# configuration is the signal the installer and the verifier both read.
mkdir -p "$test_root/config/sway"
printf 'bindsym $mod+o exec pkill -USR2 -x handy\n' >"$test_root/config/sway/config"
run_success "Standalone dictation dry-run keeps the compositor-owned key" \
  "Super+O, owned by Sway (pkill -USR2 -x handy)" \
  ./platforms/fedora/scripts/install-dictation.sh --dry-run
rm -rf "$test_root/config/sway"
run_success "Standalone dictation dry-run names the Plasma shortcut with no Sway" \
  "handy --toggle-transcription" \
  ./platforms/fedora/scripts/install-dictation.sh --dry-run
run_success "Standalone dictation dry-run configures no cloud transcription" \
  "local only; no account, API key or cloud endpoint" \
  ./platforms/fedora/scripts/install-dictation.sh --dry-run
run_success "Containers remains opt-in" "Containers profile:  false" \
  ./install.sh --dry-run
run_success "Containers dry-run" \
  "platforms/fedora/scripts/install-containers.sh" \
  ./install.sh --dry-run --containers
run_success "Containers dry-run documents no Docker Engine/alias" \
  "Docker Engine/alias:   not installed" \
  ./platforms/fedora/scripts/install-containers.sh --dry-run
run_success "Containers API socket remains opt-in" \
  "Containers API socket: false" \
  ./install.sh --dry-run --containers
run_success "Containers API socket dry-run" \
  "install-containers.sh --api-socket" \
  ./install.sh --dry-run --containers --containers-api-socket
run_success "Standalone containers dry-run" \
  "Rootless API socket:   false" \
  ./platforms/fedora/scripts/install-containers.sh --dry-run
run_success "Tailscale remains opt-in" "Tailscale profile:   false" \
  ./install.sh --dry-run
run_success "Tailscale dry-run" \
  "platforms/fedora/scripts/install-tailscale.sh" \
  ./install.sh --dry-run --tailscale
run_success "Tailscale dry-run documents no automated authentication" \
  "not automated; 'tailscale up' is never run here" \
  ./platforms/fedora/scripts/install-tailscale.sh --dry-run
run_success "Standalone Tailscale dry-run documents no embedded credentials" \
  "none (no auth key, no OAuth secret, no tailnet policy)" \
  ./platforms/fedora/scripts/install-tailscale.sh --dry-run
run_success "AI remains opt-in" "AI profile:          false" \
  ./install.sh --dry-run
run_success "AI dry-run" "common/install-ai.sh" \
  ./install.sh --dry-run --ai
run_success "AI Codex remains opt-in" "AI Codex subcomponent: inherit" \
  ./install.sh --dry-run --ai
run_success "AI Codex dry-run" "common/install-ai.sh --codex" \
  ./install.sh --dry-run --ai --codex
run_success "AI FirstMate remains opt-in" "AI FirstMate subcomponent: inherit" \
  ./install.sh --dry-run --ai
run_success "AI FirstMate dry-run" "common/install-ai.sh --firstmate" \
  ./install.sh --dry-run --ai --firstmate
run_success "AI Codex and FirstMate together dry-run" \
  "common/install-ai.sh --codex --firstmate" \
  ./install.sh --dry-run --ai --codex --firstmate
run_success "AI GNHF remains opt-in" "AI GNHF subcomponent: inherit" \
  ./install.sh --dry-run --ai
run_success "AI GNHF dry-run" "common/install-ai.sh --gnhf" \
  ./install.sh --dry-run --ai --gnhf
run_success "AI Codex, FirstMate and GNHF together dry-run" \
  "common/install-ai.sh --codex --firstmate --gnhf" \
  ./install.sh --dry-run --ai --codex --firstmate --gnhf
run_success "AI backpass remains opt-in" "AI backpass subcomponent: inherit" \
  ./install.sh --dry-run --ai
run_success "AI backpass dry-run" "common/install-ai.sh --backpass" \
  ./install.sh --dry-run --ai --backpass
run_success "AI backpass does not require FirstMate" \
  "common/install-ai.sh --backpass" \
  ./install.sh --dry-run --ai --backpass
run_success "AI everything together dry-run" \
  "common/install-ai.sh --codex --firstmate --gnhf --backpass" \
  ./install.sh --dry-run --ai --codex --firstmate --gnhf --backpass
run_success "AI explicit removal is forwarded, not silently implied" \
  "common/install-ai.sh --no-codex --no-firstmate --no-gnhf --no-backpass" \
  ./install.sh --dry-run --ai --no-codex --no-firstmate --no-gnhf --no-backpass
run_success "AI explicit removal is reported as a removal" \
  "AI Codex subcomponent: false" \
  ./install.sh --dry-run --ai --no-codex
run_failure "AI removal flags still require the AI profile" \
  "--codex/--no-codex requires --ai" \
  ./install.sh --dry-run --no-codex
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
  ./platforms/fedora/scripts/install-asus-hardware.sh --dry-run --model ga402rk

run_failure "unknown option" "Unknown option: --invalid-option" \
  ./install.sh --invalid-option
run_failure "missing theme value" "--theme requires a value" ./install.sh --theme
run_failure "invalid theme" "Invalid Catppuccin flavour: espresso" \
  ./install.sh --dry-run --theme espresso

# The accepted flavours are the theme option's values in the option manifest,
# not a second list in the installer (#242): a value added there is accepted.
flavour_manifest="$test_root/install-options.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "theme" { $7 = $7 "|oled" } { print }' \
  config/install-options.tsv >"$flavour_manifest"
run_success "a flavour added to the option manifest is accepted" \
  "Catppuccin flavour:  oled" \
  env "INSTALL_OPTION_MANIFEST=$flavour_manifest" ./install.sh --dry-run --theme oled
run_failure "a flavour the option manifest does not list is rejected" \
  "Invalid Catppuccin flavour: oled" \
  ./install.sh --dry-run --theme oled

# --dry-run exits before preflight, so it checks the capability selection
# itself (#242): a capability the manifest does not implement fails the plan
# instead of being shown as a step.
unimplemented_manifest="$test_root/capabilities.tsv"
awk -F '\t' '!($1 == "hardening" && $2 == "fedora")' \
  config/capabilities.tsv >"$unimplemented_manifest"
run_failure "a dry run refuses a capability the manifest does not implement" \
  "Capability hardening is not implemented for fedora." \
  env "CAPABILITY_MANIFEST=$unimplemented_manifest" ./install.sh --dry-run --hardening --non-interactive
assert_not_contains "$TEST_OUTPUT" "[hardening]"
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
run_failure "charge limit below the range" \
  "--charge-limit must be an integer from 40 to 100" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 39
run_success "charge limit at the bottom of the range" "charge-limit:40" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 40
run_success "charge limit at the top of the range" "charge-limit:100" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 100

# The installer reads the range from the manifest rather than keeping its own
# copy, so the bound --help and the generated reference publish is the bound a
# run enforces (#509, V4-25).
wide_manifest="$test_root/wide-charge-limit.tsv"
sed 's/\t40\.\.100\t/\t30..100\t/' config/install-options.tsv >"$wide_manifest"
grep -q $'\t30\\.\\.100\t' "$wide_manifest"
run_success "charge limit follows the manifest's range" "charge-limit:35" \
  env "INSTALL_OPTION_MANIFEST=$wide_manifest" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 35
run_failure "charge limit refusal states the manifest's range" \
  "--charge-limit must be an integer from 30 to 100" \
  env "INSTALL_OPTION_MANIFEST=$wide_manifest" \
  ./install.sh --dry-run --hardware ga402xz --charge-limit 29
run_failure "VM host and guest are mutually exclusive" \
  "--vm-host and --vm-guest cannot be combined" \
  ./install.sh --dry-run --vm-host --vm-guest
run_failure "VM guest excludes laptop hardware" \
  "--vm-guest and --hardware cannot be combined" \
  ./install.sh --dry-run --vm-guest --hardware ga402xz
run_failure "Codex requires the AI profile" "--codex/--no-codex requires --ai" \
  ./install.sh --dry-run --codex
run_failure "FirstMate requires the AI profile" "--firstmate/--no-firstmate requires --ai" \
  ./install.sh --dry-run --firstmate
run_failure "GNHF requires the AI profile" "--gnhf/--no-gnhf requires --ai" \
  ./install.sh --dry-run --gnhf
run_failure "backpass requires the AI profile" "--backpass/--no-backpass requires --ai" \
  ./install.sh --dry-run --backpass

dry_run_residue="$(find "$test_root/home" "$test_root/config" "$test_root/data" \
  "$test_root/cache" -mindepth 1 -print -quit)"
if [[ -n "$dry_run_residue" ]]; then
  printf 'Dry-runs changed isolated user state\n' >&2
  exit 1
fi

printf 'Installer option and dry-run tests passed.\n'
