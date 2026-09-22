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
# shellcheck source=../../common/lib/theme-selection.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/theme-selection.sh"
# shellcheck source=lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fedora.sh"

theme="$THEME_DEFAULT_FLAVOUR"; theme_explicit=false; install_kde=auto; install_latex=auto; install_ocaml=false
run_dev_workflows=false
install_sway=false; install_vm_host=false; install_vm_guest=false
install_hardening=false; install_desktop_tools=false
desktop_tools_force_defaults=false; install_dictation=false
install_containers=false
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
  --dictation/--no-dictation
                     Voice dictation (Handy), bound to Super+O by Sway
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
  --dev-workflows    Run the disposable development workflow smoke tests
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Never prompt; resolve every choice from the given
                     options and their defaults. Requires cached sudo
                     (run 'sudo -v' first) where the run needs it.
  -h, --help         Show this help
EOF
}

while (($#)); do
  case "$1" in
  --theme) [[ $# -ge 2 ]] || die '--theme requires a value'; theme="$2"; theme_explicit=true; shift 2 ;;
  --kde) install_kde=enabled; shift ;; --no-kde) install_kde=disabled; shift ;;
  --latex) install_latex=enabled; shift ;; --no-latex) install_latex=disabled; shift ;;
  --ocaml) install_ocaml=true; shift ;; --no-ocaml) install_ocaml=false; shift ;;
  --sway) install_sway=true; shift ;; --no-sway) install_sway=false; shift ;;
  --vm-host) install_vm_host=true; shift ;; --vm-guest) install_vm_guest=true; shift ;;
  --hardening) install_hardening=true; shift ;; --no-hardening) install_hardening=false; shift ;;
  --desktop-tools) install_desktop_tools=true; shift ;; --no-desktop-tools) install_desktop_tools=false; shift ;;
  --desktop-tools-force-defaults) desktop_tools_force_defaults=true; shift ;;
  --dictation) install_dictation=true; shift ;; --no-dictation) install_dictation=false; shift ;;
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
  --dev-workflows) run_dev_workflows=true; shift ;; --no-dev-workflows) run_dev_workflows=false; shift ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  --rerun) die '--rerun is owned by the root installer: run ./install.sh --rerun instead.' ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option: $1" ;;
  esac
done

# An explicit --theme wins; otherwise keep the flavour this machine already
# has, then the one its last successful install recorded, and only then the
# first-install default. A plain rerun must never reset a machine to the
# default (issue #148).
theme_resolve fedora "$theme_explicit" "$theme"
theme="$THEME_RESOLVED"
theme_source="$THEME_RESOLVED_SOURCE"
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

bool_kde=false; [[ "$install_kde" != enabled ]] || bool_kde=true
bool_latex=false; [[ "$install_latex" != enabled ]] || bool_latex=true

# The resolved persistent configuration of this run. Auto-detected and
# interactively answered options are recorded as what they resolved to, because
# that is the machine configuration ./install.sh --rerun must reproduce.
# Transient controls (--dry-run, --non-interactive, --dev-workflows) are
# deliberately absent: they belong to one invocation, not to the machine.
install_selection_reset fedora
install_selection_set theme "$theme"
install_selection_set kde "$bool_kde"
install_selection_set latex "$bool_latex"
install_selection_set ocaml "$install_ocaml"
install_selection_set sway "$install_sway"
install_selection_set vm-host "$install_vm_host"
install_selection_set vm-guest "$install_vm_guest"
install_selection_set hardening "$install_hardening"
install_selection_set desktop-tools "$install_desktop_tools"
install_selection_set desktop-tools-force-defaults "$desktop_tools_force_defaults"
install_selection_set dictation "$install_dictation"
install_selection_set containers "$install_containers"
install_selection_set containers-api-socket "$containers_api_socket"
install_selection_set tailscale "$install_tailscale"
install_selection_set ai "$install_ai"
install_selection_set codex "${ai_codex:-inherit}"
install_selection_set firstmate "${ai_firstmate:-inherit}"
install_selection_set gnhf "${ai_gnhf:-inherit}"
install_selection_set backpass "${ai_backpass:-inherit}"
install_selection_set hardware "${hardware_model:--}"
install_selection_set secure-boot "$hardware_secure_boot"
install_selection_set charge-limit "${hardware_charge_limit:--}"
install_selection="$(install_selection_serialize)"
# The command a failed run prints: this selection plus the transient controls
# that add work to this run's plan, because the selection deliberately leaves
# them out and a rerun without them would silently skip that work.
rerun_controls=()
[[ "$run_dev_workflows" != true ]] || rerun_controls+=(--dev-workflows)
DOTFILES_RERUN_COMMAND="$(install_lifecycle_rerun_command fedora "$install_selection" "${rerun_controls[@]}")"

hardware_args=()
[[ -z "$hardware_model" ]] || hardware_args=(--model "$hardware_model")
[[ "$hardware_secure_boot" != true ]] || hardware_args+=(--secure-boot)
[[ -z "$hardware_charge_limit" ]] || hardware_args+=(--charge-limit "$hardware_charge_limit")
hardware_selected=false
[[ -z "$hardware_model" ]] || hardware_selected=true

# The selected capability set is resolved once and reused by the selection
# check, preflight and the lifecycle record, so those three can never disagree.
fedora_selected_capabilities() {
  local selection
  printf '%s\n' base dotnet-debug
  for selection in "$bool_kde:kde" "$bool_latex:latex" "$install_ocaml:ocaml" "$install_sway:sway" "$install_vm_host:vm-host" "$install_vm_guest:vm-guest" "$hardware_selected:hardware" "$install_hardening:hardening" "$install_desktop_tools:desktop-tools" "$install_dictation:dictation" "$install_containers:containers" "$install_tailscale:tailscale" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do
    [[ "${selection%%:*}" != true ]] || printf '%s\n' "${selection#*:}"
  done
}
# Checked for every run, --dry-run included: a dry run exits before
# plan_preflight, and it must not show a plan for a capability this platform's
# manifest does not implement.
selected_capabilities=()
while IFS= read -r capability; do selected_capabilities+=("$capability"); done < <(fedora_selected_capabilities)
capability_validate_selection fedora "${selected_capabilities[@]}" ||
  die 'The selected capabilities cannot be installed on fedora.'

# Each step's command is stated once, as a repository-relative argument vector
# (see plan_command_run): its apply function runs it and its plan note prints
# it. Invocation-only controls such as --non-interactive stay with apply.
fedora_system_command() { printf '%s\n' platforms/fedora/scripts/install-system.sh; }
fedora_terra_command() { printf '%s\n' platforms/fedora/scripts/install-terra.sh; }
fedora_ocaml_native_command() { printf '%s\n' platforms/fedora/scripts/install-ocaml.sh; }
fedora_hardware_command() { printf '%s\n' platforms/fedora/scripts/install-asus-hardware.sh "${hardware_args[@]}"; }
fedora_sway_command() { printf '%s\n' platforms/fedora/scripts/install-sway.sh; }
fedora_vm_host_command() { printf '%s\n' platforms/fedora/scripts/install-vm-host.sh; }
fedora_vm_guest_command() { printf '%s\n' platforms/fedora/scripts/install-vm-guest.sh; }
fedora_hardening_command() { printf '%s\n' platforms/fedora/scripts/install-hardening.sh; }
fedora_desktop_tools_command() { printf '%s\n' platforms/fedora/scripts/install-desktop-tools.sh; [[ "$desktop_tools_force_defaults" != true ]] || printf '%s\n' --force-defaults; }
fedora_dictation_command() { printf '%s\n' platforms/fedora/scripts/install-dictation.sh; }
fedora_containers_command() { printf '%s\n' platforms/fedora/scripts/install-containers.sh; [[ "$containers_api_socket" != true ]] || printf '%s\n' --api-socket; }
fedora_tailscale_command() { printf '%s\n' platforms/fedora/scripts/install-tailscale.sh; }
fedora_local_command() { printf '%s\n' platforms/fedora/scripts/setup-local.sh "$theme"; [[ "$install_sway" != true ]] || { printf '%s\n' --sway; [[ -z "$hardware_model" ]] || printf '%s\n' --hardware "$hardware_model"; }; }
fedora_stow_command() { printf '%s\n' platforms/fedora/scripts/stow.sh; [[ "$install_sway" != true ]] || printf '%s\n' --sway; }
fedora_mise_command() { printf '%s\n' common/install-mise.sh; }
fedora_nvim_command() { printf '%s\n' common/install-neovim-tools.sh; }
fedora_tmux_command() { printf '%s\n' common/install-tmux-theme.sh; }
fedora_ocaml_command() { printf '%s\n' common/install-ocaml.sh; }
fedora_ai_command() {
  printf '%s\n' common/install-ai.sh
  case "$ai_codex" in true) printf '%s\n' --codex ;; false) printf '%s\n' --no-codex ;; esac
  case "$ai_firstmate" in true) printf '%s\n' --firstmate ;; false) printf '%s\n' --no-firstmate ;; esac
  case "$ai_gnhf" in true) printf '%s\n' --gnhf ;; false) printf '%s\n' --no-gnhf ;; esac
  case "$ai_backpass" in true) printf '%s\n' --backpass ;; false) printf '%s\n' --no-backpass ;; esac
}
fedora_kde_command() { printf '%s\n' platforms/fedora/scripts/install-kde-theme.sh; }
fedora_latex_command() { printf '%s\n' platforms/fedora/scripts/install-latex.sh; }
fedora_dev_workflows_command() { printf '%s\n' scripts/test-dev-workflows.sh --all; [[ "$install_ocaml" != true ]] || printf '%s\n' --ocaml; [[ "$install_latex" != enabled ]] || printf '%s\n' --latex; }
fedora_verify_command() { printf '%s\n' platforms/fedora/scripts/verify.sh; }

preflight_fedora() {
  # First, and before every other check: an unsupported XDG root would have
  # Stow deploy to a place the rest of the install never reads. It is a pure
  # lexical comparison with no prerequisites, so it really can go first --
  # ahead of preflight_sudo, which prompts for a password on a run that is
  # about to be refused.
  preflight_xdg_layout
  require_regular_user; require_fedora
  preflight_platform_command_providers fedora; preflight_sudo "$interactive"
  # The hardening profile is the one selected step that asks the user to agree
  # to it, and the plan has no way to skip a step: a no during execution can
  # only fail the run, after everything before it has already been installed.
  # So the question is asked here instead, while nothing has been changed yet
  # and the plan is still just a list. --confirm changes nothing on its own.
  [[ "$install_hardening" != true || "$interactive" != true ]] || plan_command_run fedora_hardening_command --confirm
  [[ "$install_vm_guest" != true ]] || plan_command_run fedora_vm_guest_command --preflight
  [[ -z "$hardware_model" ]] || plan_command_run fedora_hardware_command --preflight
  preflight_writable_path "$HOME"; preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"; preflight_writable_path "$(profile_state_dir)"
  preflight_disk_space "$XDG_DATA_HOME" "$PREFLIGHT_USER_DATA_MIN_MB"
  preflight_disk_space /var/cache/dnf "$PREFLIGHT_SYSTEM_MIN_MB"
  local specs=() spec capability stow_specs exemption
  local selected=() packages=() replaced=()
  while IFS= read -r capability; do selected+=("$capability"); done < <(fedora_selected_capabilities)
  capability_validate_selection fedora "${selected[@]}"
  # A checked substitution, not < <(...): a manifest header without the stow
  # column must stop preflight, not silently skip the conflict check.
  stow_specs="$(capability_stow_specs fedora "${selected[@]}")" || return
  while IFS= read -r spec; do
    [[ -z "$spec" ]] || { specs+=("$spec"); packages+=("${spec#*::}"); }
  done <<<"$stow_specs"
  while IFS= read -r exemption; do replaced+=("$exemption"); done \
    < <(fedora_retired_link_exemptions ${packages[@]+"${packages[@]}"})
  preflight_stow_packages ${replaced[@]+"${replaced[@]}"} "${specs[@]}"
}

apply_system() { plan_command_run fedora_system_command; }
apply_terra() { plan_command_run fedora_terra_command; }
apply_ocaml_native() { plan_command_run fedora_ocaml_native_command; }
apply_hardware() { local args=(); [[ "$interactive" == true ]] || args+=(--non-interactive); plan_command_run fedora_hardware_command "${args[@]}"; }
apply_sway() { plan_command_run fedora_sway_command; }
apply_vm_host() { plan_command_run fedora_vm_host_command; }
apply_vm_guest() { plan_command_run fedora_vm_guest_command; }
# Always --non-interactive: consent was taken in preflight_fedora, and asking
# again here would put the same question after the point where a no is free.
apply_hardening() { plan_command_run fedora_hardening_command --non-interactive; }
apply_desktop() { plan_command_run fedora_desktop_tools_command; }
apply_dictation() { plan_command_run fedora_dictation_command; }
apply_containers() { plan_command_run fedora_containers_command; }
apply_tailscale() { plan_command_run fedora_tailscale_command; }
apply_local() { plan_command_run fedora_local_command; }
apply_stow() { plan_command_run fedora_stow_command; }
apply_mise() { plan_command_run fedora_mise_command; }
apply_nvim() { plan_command_run fedora_nvim_command; }
apply_tmux() { plan_command_run fedora_tmux_command; }
apply_ocaml() { plan_command_run fedora_ocaml_command; }
apply_ai() { local args=(); [[ "$interactive" == true ]] || args+=(--non-interactive); plan_command_run fedora_ai_command "${args[@]}"; }
apply_kde() { plan_command_run fedora_kde_command; }
apply_latex() { plan_command_run fedora_latex_command; }
apply_theme() { theme_apply_stowed "$theme"; }
verify_fedora() { plan_command_run fedora_verify_command; }
apply_dev_workflows() { plan_command_run fedora_dev_workflows_command; }

plan_add system 'Install Fedora system packages' apply preflight_fedora apply_system : "Set Zsh as the user's default login shell. $(plan_command_note fedora_system_command)" 'platforms/fedora/scripts/install-system.sh'
plan_add terra 'Enable Terra and install Terra-managed packages' apply : apply_terra : "$(plan_command_note fedora_terra_command)" 'platforms/fedora/scripts/install-terra.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml-native 'Install Fedora-owned OCaml prerequisites' apply : apply_ocaml_native : "$(plan_command_note fedora_ocaml_native_command)" 'platforms/fedora/scripts/install-ocaml.sh'
[[ -z "$hardware_model" ]] || plan_add hardware "Install ASUS hardware support for $hardware_model" apply : apply_hardware : "$(plan_command_note fedora_hardware_command)" 'platforms/fedora/scripts/install-asus-hardware.sh'
[[ "$install_sway" != true ]] || plan_add sway 'Install the optional Sway daily-driver session' apply : apply_sway : "$(plan_command_note fedora_sway_command)" 'platforms/fedora/scripts/install-sway.sh'
[[ "$install_vm_host" != true ]] || plan_add vm-host 'Install the optional Fedora KVM/QEMU + libvirt VM-host profile' apply : apply_vm_host : "$(plan_command_note fedora_vm_host_command); adds you to the root-equivalent libvirt group" 'platforms/fedora/scripts/install-vm-host.sh'
[[ "$install_vm_guest" != true ]] || plan_add vm-guest 'Install the explicit Fedora KVM/QEMU VM-guest profile' apply : apply_vm_guest : "$(plan_command_note fedora_vm_guest_command)" 'platforms/fedora/scripts/install-vm-guest.sh'
[[ "$install_hardening" != true ]] || plan_add hardening 'Install the optional conservative security-hardening profile' apply : apply_hardening : "$(plan_command_note fedora_hardening_command)" 'platforms/fedora/scripts/install-hardening.sh'
[[ "$install_desktop_tools" != true ]] || plan_add desktop-tools 'Install the optional day-to-day desktop application profile' apply : apply_desktop : "$(plan_command_note fedora_desktop_tools_command); GIMP, pdfarranger, mpv, Skanpage; reuses Gwenview, Okular, Ark" 'platforms/fedora/scripts/install-desktop-tools.sh'
[[ "$install_dictation" != true ]] || plan_add dictation 'Install the optional voice-dictation profile' apply : apply_dictation : "$(plan_command_note fedora_dictation_command); Handy from a pinned, digest-verified release rpm, plus wtype and gtk-layer-shell" 'platforms/fedora/scripts/install-dictation.sh'
[[ "$install_containers" != true ]] || plan_add containers 'Install the optional rootless Podman profile' apply : apply_containers : "$(plan_command_note fedora_containers_command)" 'platforms/fedora/scripts/install-containers.sh'
[[ "$install_tailscale" != true ]] || plan_add tailscale 'Install the optional Tailscale networking profile' apply : apply_tailscale : "$(plan_command_note fedora_tailscale_command)" 'platforms/fedora/scripts/install-tailscale.sh'
plan_add local 'Initialize machine-local configuration' apply : apply_local : "$(plan_command_note fedora_local_command)" 'platforms/fedora/scripts/setup-local.sh'
plan_add stow 'Deploy tracked configuration with GNU Stow' apply : apply_stow : "$(plan_command_note fedora_stow_command)" 'platforms/fedora/scripts/stow.sh'
plan_add mise 'Install mise-managed runtimes and developer tools' apply : apply_mise : "$(plan_command_note fedora_mise_command)" 'common/install-mise.sh'
plan_add nvim 'Restore LazyVim and install the Mason inventory' apply : apply_nvim : "$(plan_command_note fedora_nvim_command)" 'common/install-neovim-tools.sh'
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux : "$(plan_command_note fedora_tmux_command)" 'common/install-tmux-theme.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml 'Create the opam-owned OCaml switch and Platform tools' apply : apply_ocaml : "OCaml ${OCAML_COMPILER_VERSION:-5.5.0}; $(plan_command_note fedora_ocaml_command)" 'common/install-ocaml.sh'
[[ "$install_ai" != true ]] || plan_add ai 'Install the optional AI-assisted development profile' apply : apply_ai : "$(plan_command_note fedora_ai_command)" 'common/install-ai.sh'
[[ "$install_kde" != enabled ]] || plan_add kde 'Install all four Catppuccin KDE themes' apply : apply_kde : "$(plan_command_note fedora_kde_command)" 'platforms/fedora/scripts/install-kde-theme.sh'
[[ "$install_latex" != enabled ]] || plan_add latex 'Install LaTeX toolchain' apply : apply_latex : "$(plan_command_note fedora_latex_command)" 'platforms/fedora/scripts/install-latex.sh'
plan_add theme "Apply Catppuccin $theme" apply : apply_theme : "theme $theme" ''
[[ "$run_dev_workflows" != true ]] || plan_add dev-workflows 'Run the disposable development workflow smoke tests' verify : apply_dev_workflows : "$(plan_command_note fedora_dev_workflows_command)" 'scripts/test-dev-workflows.sh'
plan_add verify 'Verify installation' verify : verify_fedora : "$(plan_command_note fedora_verify_command)" 'platforms/fedora/scripts/verify.sh'

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Dotfiles installation plan
--------------------------
Catppuccin flavour:  $theme  (source: $theme_source — $(theme_source_description "$theme_source"))
KDE integration:     $bool_kde
LaTeX toolchain:     $bool_latex
OCaml profile:       $install_ocaml
Sway session:        $install_sway
VM-host profile:     $install_vm_host
VM-guest profile:    $install_vm_guest
Hardening profile:   $install_hardening
Desktop tools:       $install_desktop_tools
Force app defaults:  $desktop_tools_force_defaults
Dictation profile:   $install_dictation
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
Development workflow smoke tests: $run_dev_workflows  (this run only)
Recorded rerun selection: $install_selection
Rerun if this run fails: $DOTFILES_RERUN_COMMAND

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
  printf 'Catppuccin flavour: %s (source: %s — %s)\n' \
    "$theme" "$theme_source" "$(theme_source_description "$theme_source")"
  if confirm 'Continue with installation?' y; then :; else
    result=$?; ((result == 1)) || die 'Invalid confirmation response'; printf 'Cancelled; no changes made.\n'; exit 0
  fi
fi
plan_preflight
# Then the network, because a local problem is worth reporting without waiting
# for a probe. The hosts come from config/network-sources.tsv, selected by the
# scripts this resolved plan will run, so a step added later cannot fetch from
# a host nothing checked; scripts/validate-plan-network.py holds the two to
# each other. Nothing has mutated yet at this point.
plan_scripts | preflight_plan_network
capabilities=''
while IFS= read -r capability; do capabilities+="${capabilities:+,}$capability"; done < <(fedora_selected_capabilities)
install_lifecycle_begin fedora "$capabilities" "$DOTFILES_RERUN_COMMAND" "$install_selection"
if plan_execute; then :; else
  result=$?; install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"; exit "$result"
fi
install_lifecycle_commit
printf '\nInstallation completed successfully.\n'
install_lifecycle_rerun_hint
