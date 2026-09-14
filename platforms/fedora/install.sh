#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
# shellcheck source=../../common/lib/execution-plan.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/execution-plan.sh"
# shellcheck source=../../common/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/preflight.sh"
# shellcheck source=../../common/lib/capabilities.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/capabilities.sh"
# shellcheck source=../../common/lib/install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/install-lifecycle.sh"
# shellcheck source=lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fedora.sh"

theme=macchiato; install_kde=auto; install_latex=auto; install_ocaml=false
install_sway=false; install_vm_host=false; install_vm_guest=false
install_hardening=false; install_desktop_tools=false
desktop_tools_force_defaults=false; install_containers=false
containers_api_socket=false; install_tailscale=false; install_ai=false
# Empty means the sub-flag was omitted. install-ai.sh treats that as
# additive -- keep whatever is already installed -- so it must stay
# distinguishable from an explicit --no-<component> removal request.
ai_codex=''; ai_firstmate=''; ai_gnhf=''; ai_backpass=''
hardware_model=''; hardware_secure_boot=false; hardware_charge_limit=''
interactive=true; dry_run=false

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform fedora [options]

Direct entry point: ./platforms/fedora/install.sh [options]

Options:
  --theme FLAVOUR    latte, frappe, macchiato, mocha (default: macchiato)
  --kde/--no-kde     KDE integration (default: auto-detect)
  --latex/--no-latex LaTeX toolchain (default: ask interactively, otherwise off)
  --ocaml/--no-ocaml
  --sway/--no-sway
  --vm-host          KVM/QEMU + libvirt host profile
  --vm-guest         Explicit Fedora KVM/QEMU guest profile
  --hardening/--no-hardening
  --desktop-tools/--no-desktop-tools
  --desktop-tools-force-defaults
  --containers/--no-containers
  --containers-api-socket
  --tailscale/--no-tailscale
  --ai/--no-ai       Claude Code and Herdr profile
  --codex/--no-codex, --firstmate/--no-firstmate
  --gnhf/--no-gnhf, --backpass/--no-backpass
                     AI subcomponents are additive: omitting one leaves it
                     installed. --no-<component> is the only thing that
                     removes one, and it confirms first.
  --hardware MODEL   ga402xz or ga402rk
  --secure-boot      Require Secure Boot for selected hardware
  --charge-limit N   ASUS battery limit (40-100)
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Use defaults without prompting (requires cached sudo)
  -h, --help         Show this help
EOF
}

while (($#)); do
  case "$1" in
  --theme) [[ $# -ge 2 ]] || die '--theme requires a value'; theme="$2"; shift 2 ;;
  --kde) install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;
  --latex) install_latex=enabled; shift ;; --no-latex) install_latex=disabled; shift ;;
  --ocaml) install_ocaml=true; shift ;; --no-ocaml) install_ocaml=false; shift ;;
  --sway) install_sway=true; shift ;; --no-sway) install_sway=false; shift ;;
  --vm-host) install_vm_host=true; shift ;; --vm-guest) install_vm_guest=true; shift ;;
  --hardening) install_hardening=true; shift ;; --no-hardening) install_hardening=false; shift ;;
  --desktop-tools) install_desktop_tools=true; shift ;; --no-desktop-tools) install_desktop_tools=false; shift ;;
  --desktop-tools-force-defaults) desktop_tools_force_defaults=true; shift ;;
  --containers) install_containers=true; shift ;; --no-containers) install_containers=false; shift ;;
  --containers-api-socket) containers_api_socket=true; shift ;;
  --tailscale) install_tailscale=true; shift ;; --no-tailscale) install_tailscale=false; shift ;;
  --ai) install_ai=true; shift ;; --no-ai) install_ai=false; shift ;;
  --codex) ai_codex=true; shift ;; --no-codex) ai_codex=false; shift ;;
  --firstmate) ai_firstmate=true; shift ;; --no-firstmate) ai_firstmate=false; shift ;;
  --gnhf) ai_gnhf=true; shift ;; --no-gnhf) ai_gnhf=false; shift ;;
  --backpass) ai_backpass=true; shift ;; --no-backpass) ai_backpass=false; shift ;;
  --hardware) [[ $# -ge 2 ]] || die '--hardware requires a value'; hardware_model="$2"; shift 2 ;;
  --secure-boot) hardware_secure_boot=true; shift ;;
  --charge-limit) [[ $# -ge 2 ]] || die '--charge-limit requires a value'; hardware_charge_limit="$2"; shift 2 ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option: $1" ;;
  esac
done

case "$theme" in latte | frappe | macchiato | mocha) ;; *) die "Invalid Catppuccin flavour: $theme" ;; esac
case "$hardware_model" in '' | ga402xz | ga402rk) ;; *) die "Invalid hardware profile: $hardware_model" ;; esac
[[ "$hardware_secure_boot" != true || -n "$hardware_model" ]] || die '--secure-boot requires --hardware'
[[ "$desktop_tools_force_defaults" != true || "$install_desktop_tools" == true ]] || die '--desktop-tools-force-defaults requires --desktop-tools'
[[ "$containers_api_socket" != true || "$install_containers" == true ]] || die '--containers-api-socket requires --containers'
[[ -z "$ai_codex" || "$install_ai" == true ]] || die '--codex/--no-codex requires --ai'
[[ -z "$ai_firstmate" || "$install_ai" == true ]] || die '--firstmate/--no-firstmate requires --ai'
[[ -z "$ai_gnhf" || "$install_ai" == true ]] || die '--gnhf/--no-gnhf requires --ai'
[[ -z "$ai_backpass" || "$install_ai" == true ]] || die '--backpass/--no-backpass requires --ai'
[[ "$install_vm_host" != true || "$install_vm_guest" != true ]] || die '--vm-host and --vm-guest cannot be combined'
[[ "$install_vm_guest" != true || -z "$hardware_model" ]] || die '--vm-guest and --hardware cannot be combined'
if [[ -n "$hardware_charge_limit" ]]; then
  [[ -n "$hardware_model" ]] || die '--charge-limit requires --hardware'
  if [[ ! "$hardware_charge_limit" =~ ^[0-9]+$ ]] ||
    ((hardware_charge_limit < 40 || hardware_charge_limit > 100)); then
    die '--charge-limit must be an integer from 40 to 100'
  fi
fi

if [[ "$install_kde" == auto ]]; then command_exists plasmashell && install_kde=enabled || install_kde=disabled; fi
if [[ "$install_latex" == auto && "$interactive" == true ]]; then
  if confirm 'Install LaTeX toolchain?' n; then install_latex=enabled; else
    result=$?; ((result == 1)) || die 'Invalid confirmation response'; install_latex=disabled
  fi
elif [[ "$install_latex" == auto ]]; then install_latex=disabled
fi

hardware_args=()
[[ -z "$hardware_model" ]] || hardware_args=(--model "$hardware_model")
[[ "$hardware_secure_boot" != true ]] || hardware_args+=(--secure-boot)
[[ -z "$hardware_charge_limit" ]] || hardware_args+=(--charge-limit "$hardware_charge_limit")
hardware_selected=false
[[ -z "$hardware_model" ]] || hardware_selected=true

build_rerun_command() {
  local args=(./install.sh --platform fedora --theme "$theme")
  local arg rendered='' quoted

  if [[ "$bool_kde" == true ]]; then args+=(--kde); else args+=(--no-kde); fi
  if [[ "$bool_latex" == true ]]; then args+=(--latex); else args+=(--no-latex); fi
  [[ "$install_ocaml" != true ]] || args+=(--ocaml)
  [[ "$install_sway" != true ]] || args+=(--sway)
  [[ "$install_vm_host" != true ]] || args+=(--vm-host)
  [[ "$install_vm_guest" != true ]] || args+=(--vm-guest)
  [[ "$install_hardening" != true ]] || args+=(--hardening)
  [[ "$install_desktop_tools" != true ]] || args+=(--desktop-tools)
  [[ "$desktop_tools_force_defaults" != true ]] || args+=(--desktop-tools-force-defaults)
  [[ "$install_containers" != true ]] || args+=(--containers)
  [[ "$containers_api_socket" != true ]] || args+=(--containers-api-socket)
  [[ "$install_tailscale" != true ]] || args+=(--tailscale)
  [[ "$install_ai" != true ]] || args+=(--ai)
  case "$ai_codex" in true) args+=(--codex) ;; false) args+=(--no-codex) ;; esac
  case "$ai_firstmate" in true) args+=(--firstmate) ;; false) args+=(--no-firstmate) ;; esac
  case "$ai_gnhf" in true) args+=(--gnhf) ;; false) args+=(--no-gnhf) ;; esac
  case "$ai_backpass" in true) args+=(--backpass) ;; false) args+=(--no-backpass) ;; esac
  if [[ "$hardware_selected" == true ]]; then
    args+=(--hardware "$hardware_model")
    [[ "$hardware_secure_boot" != true ]] || args+=(--secure-boot)
    [[ -z "$hardware_charge_limit" ]] || args+=(--charge-limit "$hardware_charge_limit")
  fi
  args+=(--non-interactive)

  for arg in "${args[@]}"; do
    printf -v quoted '%q' "$arg"
    rendered+="${rendered:+ }$quoted"
  done
  printf '%s\n' "$rendered"
}

preflight_fedora() {
  require_regular_user; require_fedora
  preflight_platform_command_providers fedora; preflight_sudo "$interactive"
  [[ "$install_vm_guest" != true ]] || "$DOTFILES_ROOT/platforms/fedora/scripts/install-vm-guest.sh" --preflight
  [[ -z "$hardware_model" ]] || "$DOTFILES_ROOT/platforms/fedora/scripts/install-asus-hardware.sh" "${hardware_args[@]}" --preflight
  preflight_writable_path "$HOME"; preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"; preflight_writable_path "$(profile_state_dir)"
  local specs=() capability
  local selected=(base dotnet-debug)
  for selection in "$bool_kde:kde" "$bool_latex:latex" "$install_ocaml:ocaml" "$install_sway:sway" "$install_vm_host:vm-host" "$install_vm_guest:vm-guest" "$hardware_selected:hardware" "$install_hardening:hardening" "$install_desktop_tools:desktop-tools" "$install_containers:containers" "$install_tailscale:tailscale" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do
    [[ "${selection%%:*}" != true ]] || selected+=("${selection#*:}")
  done
  capability_validate_selection fedora "${selected[@]}"
  while IFS= read -r capability; do specs+=("$capability"); done < <(capability_stow_specs fedora "${selected[@]}")
  preflight_stow_packages "${specs[@]}"
}

apply_system() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-system.sh"; }
apply_terra() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-terra.sh"; }
apply_ocaml_native() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-ocaml.sh"; }
apply_hardware() { local args=("${hardware_args[@]}"); [[ "$interactive" == true ]] || args+=(--non-interactive); "$DOTFILES_ROOT/platforms/fedora/scripts/install-asus-hardware.sh" "${args[@]}"; }
apply_sway() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-sway.sh"; }
apply_vm_host() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-vm-host.sh"; }
apply_vm_guest() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-vm-guest.sh"; }
apply_hardening() { local args=(); [[ "$interactive" == true ]] || args+=(--non-interactive); "$DOTFILES_ROOT/platforms/fedora/scripts/install-hardening.sh" "${args[@]}"; }
apply_desktop() { local args=(); [[ "$desktop_tools_force_defaults" != true ]] || args+=(--force-defaults); "$DOTFILES_ROOT/platforms/fedora/scripts/install-desktop-tools.sh" "${args[@]}"; }
apply_containers() { local args=(); [[ "$containers_api_socket" != true ]] || args+=(--api-socket); "$DOTFILES_ROOT/platforms/fedora/scripts/install-containers.sh" "${args[@]}"; }
apply_tailscale() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-tailscale.sh"; }
apply_local() { local args=("$theme"); [[ "$install_sway" != true ]] || { args+=(--sway); [[ -z "$hardware_model" ]] || args+=(--hardware "$hardware_model"); }; "$DOTFILES_ROOT/platforms/fedora/scripts/setup-local.sh" "${args[@]}"; }
apply_stow() { local args=(); [[ "$install_sway" != true ]] || args+=(--sway); "$DOTFILES_ROOT/platforms/fedora/scripts/stow.sh" "${args[@]}"; }
apply_mise() { "$DOTFILES_ROOT/common/install-mise.sh"; }
apply_nvim() { "$DOTFILES_ROOT/common/install-neovim-tools.sh"; }
apply_tmux() { "$DOTFILES_ROOT/common/install-tmux-theme.sh"; }
apply_ocaml() { "$DOTFILES_ROOT/common/install-ocaml.sh"; }
apply_ai() { local args=(); case "$ai_codex" in true) args+=(--codex) ;; false) args+=(--no-codex) ;; esac; case "$ai_firstmate" in true) args+=(--firstmate) ;; false) args+=(--no-firstmate) ;; esac; case "$ai_gnhf" in true) args+=(--gnhf) ;; false) args+=(--no-gnhf) ;; esac; case "$ai_backpass" in true) args+=(--backpass) ;; false) args+=(--no-backpass) ;; esac; [[ "$interactive" == true ]] || args+=(--non-interactive); "$DOTFILES_ROOT/common/install-ai.sh" "${args[@]}"; }
apply_kde() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-kde-theme.sh"; }
apply_latex() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-latex.sh"; }
apply_theme() { [[ ! -x "$HOME/.local/bin/theme" ]] || "$HOME/.local/bin/theme" "$theme"; }
verify_fedora() { "$DOTFILES_ROOT/platforms/fedora/scripts/verify.sh"; }

plan_add system 'Install Fedora system packages' apply preflight_fedora apply_system : "Set Zsh as the user's default login shell. platforms/fedora/scripts/install-system.sh"
plan_add terra 'Enable Terra and install Terra-managed packages' apply : apply_terra : 'platforms/fedora/scripts/install-terra.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml-native 'Install Fedora-owned OCaml prerequisites' apply : apply_ocaml_native : 'platforms/fedora/scripts/install-ocaml.sh'
[[ -z "$hardware_model" ]] || plan_add hardware "Install ASUS hardware support for $hardware_model" apply : apply_hardware : "platforms/fedora/scripts/install-asus-hardware.sh --model $hardware_model"
[[ "$install_sway" != true ]] || plan_add sway 'Install the optional Sway daily-driver session' apply : apply_sway : 'platforms/fedora/scripts/install-sway.sh'
[[ "$install_vm_host" != true ]] || plan_add vm-host 'Install the optional Fedora KVM/QEMU + libvirt VM-host profile' apply : apply_vm_host : 'platforms/fedora/scripts/install-vm-host.sh'
[[ "$install_vm_guest" != true ]] || plan_add vm-guest 'Install the explicit Fedora KVM/QEMU VM-guest profile' apply : apply_vm_guest : 'platforms/fedora/scripts/install-vm-guest.sh'
[[ "$install_hardening" != true ]] || plan_add hardening 'Install the optional conservative security-hardening profile' apply : apply_hardening : 'platforms/fedora/scripts/install-hardening.sh'
if [[ "$install_desktop_tools" == true ]]; then desktop_note='platforms/fedora/scripts/install-desktop-tools.sh'; [[ "$desktop_tools_force_defaults" != true ]] || desktop_note+=' --force-defaults'; desktop_note+='; GIMP, pdfarranger, mpv, Skanpage; reuses Gwenview, Okular, Ark'; plan_add desktop-tools 'Install the optional day-to-day desktop application profile' apply : apply_desktop : "$desktop_note"; fi
if [[ "$install_containers" == true ]]; then containers_note='platforms/fedora/scripts/install-containers.sh'; [[ "$containers_api_socket" != true ]] || containers_note+=' --api-socket'; plan_add containers 'Install the optional rootless Podman profile' apply : apply_containers : "$containers_note"; fi
[[ "$install_tailscale" != true ]] || plan_add tailscale 'Install the optional Tailscale networking profile' apply : apply_tailscale : 'platforms/fedora/scripts/install-tailscale.sh'
local_note="platforms/fedora/scripts/setup-local.sh $theme"; [[ "$install_sway" != true ]] || { local_note+=' --sway'; [[ -z "$hardware_model" ]] || local_note+=" --hardware $hardware_model"; }
plan_add local 'Initialize machine-local configuration' apply : apply_local : "$local_note"
stow_note='platforms/fedora/scripts/stow.sh'; [[ "$install_sway" != true ]] || stow_note+=' --sway'
plan_add stow 'Deploy tracked configuration with GNU Stow' apply : apply_stow : "$stow_note"
plan_add mise 'Install mise-managed runtimes and developer tools' apply : apply_mise : 'common/install-mise.sh'
plan_add nvim 'Restore LazyVim and install the Mason inventory' apply : apply_nvim : 'common/install-neovim-tools.sh'
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux : 'common/install-tmux-theme.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml 'Create the opam-owned OCaml switch and Platform tools' apply : apply_ocaml : "OCaml ${OCAML_COMPILER_VERSION:-5.5.0}; common/install-ocaml.sh"
if [[ "$install_ai" == true ]]; then ai_note='common/install-ai.sh'; case "$ai_codex" in true) ai_note+=' --codex' ;; false) ai_note+=' --no-codex' ;; esac; case "$ai_firstmate" in true) ai_note+=' --firstmate' ;; false) ai_note+=' --no-firstmate' ;; esac; case "$ai_gnhf" in true) ai_note+=' --gnhf' ;; false) ai_note+=' --no-gnhf' ;; esac; case "$ai_backpass" in true) ai_note+=' --backpass' ;; false) ai_note+=' --no-backpass' ;; esac; plan_add ai 'Install the optional AI-assisted development profile' apply : apply_ai : "$ai_note"; fi
[[ "$install_kde" != enabled ]] || plan_add kde 'Install all four Catppuccin KDE themes' apply : apply_kde : 'platforms/fedora/scripts/install-kde-theme.sh'
[[ "$install_latex" != enabled ]] || plan_add latex 'Install LaTeX toolchain' apply : apply_latex : 'platforms/fedora/scripts/install-latex.sh'
plan_add theme "Apply Catppuccin $theme" apply : apply_theme : "theme $theme"
plan_add verify 'Verify installation' verify : verify_fedora : 'platforms/fedora/scripts/verify.sh'

bool_kde=false; [[ "$install_kde" != enabled ]] || bool_kde=true
bool_latex=false; [[ "$install_latex" != enabled ]] || bool_latex=true
if [[ "$dry_run" == true ]]; then
  cat <<EOF

Dotfiles installation plan
--------------------------
Catppuccin flavour:  $theme
KDE integration:     $bool_kde
LaTeX toolchain:     $bool_latex
OCaml profile:       $install_ocaml
Sway session:        $install_sway
VM-host profile:     $install_vm_host
VM-guest profile:    $install_vm_guest
Hardening profile:   $install_hardening
Desktop tools:       $install_desktop_tools
Force app defaults:  $desktop_tools_force_defaults
Containers profile:  $install_containers
Containers API socket: $containers_api_socket
Tailscale profile:   $install_tailscale
AI profile:          $install_ai
AI Codex subcomponent: ${ai_codex:-inherit}
AI FirstMate subcomponent: ${ai_firstmate:-inherit}
AI GNHF subcomponent: ${ai_gnhf:-inherit}
AI backpass subcomponent: ${ai_backpass:-inherit}
ASUS hardware:       ${hardware_model:-disabled}
Require Secure Boot: $hardware_secure_boot
Battery limit:       ${hardware_charge_limit:-unchanged}

EOF
  plan_render
  cat <<'EOF'

Manual configuration still required afterward:
  • If the login shell changed, reboot so Plasma and user services refresh SHELL.
  • Configure Git identity, SSH authentication, and `gh auth login`.

No changes were made.
EOF
  exit 0
fi

if [[ "$interactive" == true ]]; then
  printf '\nInstallation choices resolved.\n'
  if confirm 'Continue with installation?' y; then :; else
    result=$?; ((result == 1)) || die 'Invalid confirmation response'; printf 'Cancelled; no changes made.\n'; exit 0
  fi
fi
plan_preflight
capabilities=base,dotnet-debug
for selection in "$bool_kde:kde" "$bool_latex:latex" "$install_ocaml:ocaml" "$install_sway:sway" "$install_vm_host:vm-host" "$install_vm_guest:vm-guest" "$hardware_selected:hardware" "$install_hardening:hardening" "$install_desktop_tools:desktop-tools" "$install_containers:containers" "$install_tailscale:tailscale" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do [[ "${selection%%:*}" != true ]] || capabilities+=,"${selection#*:}"; done
DOTFILES_RERUN_COMMAND="$(build_rerun_command)"
install_lifecycle_begin fedora "$capabilities" "$DOTFILES_RERUN_COMMAND"
if plan_execute; then :; else
  result=$?; install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"; exit "$result"
fi
install_lifecycle_commit
printf '\nInstallation completed successfully.\n'
