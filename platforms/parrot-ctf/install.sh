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
# shellcheck source=lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/parrot.sh"

theme="$THEME_DEFAULT_FLAVOUR"
theme_explicit=false
interactive=true
dry_run=false

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform parrot-ctf [options]

Direct entry point: ./platforms/parrot-ctf/install.sh [options]

Options:
  --theme FLAVOUR    latte, frappe, macchiato, or mocha (default: macchiato)
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Never prompt; resolve every choice from the given
                     options and their defaults. Requires cached sudo
                     (run 'sudo -v' first) where the run needs it.
  -h, --help         Show this help

This is a KVM/QEMU lab-guest profile. Parrot owns its security catalogue;
Fedora, desktop, VM-host, LaTeX, OCaml, containers, and AI are unsupported.
Development workflow smoke tests (--dev-workflows) are unsupported too: the
reduced profile has no workstation language runtimes to exercise.
EOF
}

while (($#)); do
  case "$1" in
  --theme)
    [[ $# -ge 2 ]] || die "--theme requires a value"
    theme="$2"
    theme_explicit=true
    shift 2
    ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  --rerun) die '--rerun is owned by the root installer: run ./install.sh --rerun instead.' ;;
  --dev-workflows | --no-dev-workflows | --smoke-test | --workflows | --no-workflows)
    die 'Development workflow smoke tests are not supported on parrot-ctf: the reduced profile deliberately has no .NET, Node or Angular runtime. Run them on a workstation profile instead.' ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option for parrot-ctf: $1" ;;
  esac
done
# An explicit --theme wins; otherwise keep the flavour this machine already
# has, then the one its last successful install recorded, and only then the
# first-install default. A plain rerun must never reset a machine to the
# default (issue #148).
theme_resolve parrot-ctf "$theme_explicit" "$theme"
theme="$THEME_RESOLVED"
theme_source="$THEME_RESOLVED_SOURCE"

# The resolved persistent configuration of this run; transient controls
# (--dry-run, --non-interactive) are deliberately excluded.
install_selection_reset parrot-ctf
install_selection_set theme "$theme"
install_selection="$(install_selection_serialize)"

# The reduced guest has no optional capabilities: its selection is fixed, and
# still resolved in one place for the selection check, preflight and the
# lifecycle record.
parrot_selected_capabilities() { printf '%s\n' base vm-guest; }
# Checked for every run, --dry-run included: a dry run exits before
# plan_preflight, and it must not show a plan for a capability this platform's
# manifest does not implement.
selected_capabilities=()
while IFS= read -r capability; do selected_capabilities+=("$capability"); done < <(parrot_selected_capabilities)
capability_validate_selection parrot-ctf "${selected_capabilities[@]}" ||
  die 'The selected capabilities cannot be installed on parrot-ctf.'

preflight_parrot() {
  require_regular_user
  require_parrot
  require_qemu_vm >/dev/null
  require_guest_channels
  preflight_platform_command_providers parrot-ctf
  preflight_sudo "$interactive"
  preflight_writable_path "$HOME"
  preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"
  preflight_writable_path "$(profile_state_dir)"
  preflight_disk_space "$XDG_DATA_HOME" "$PREFLIGHT_USER_DATA_MIN_MB"
  preflight_disk_space /var/cache/apt "$PREFLIGHT_SYSTEM_MIN_MB"
  local specs=() spec capability stow_specs
  local selected=()
  while IFS= read -r capability; do selected+=("$capability"); done < <(parrot_selected_capabilities)
  capability_validate_selection parrot-ctf "${selected[@]}"
  # A checked substitution, not < <(...): a manifest header without the stow
  # column must stop preflight, not silently skip the conflict check.
  stow_specs="$(capability_stow_specs parrot-ctf "${selected[@]}")" || return
  while IFS= read -r spec; do [[ -z "$spec" ]] || specs+=("$spec"); done <<<"$stow_specs"
  preflight_stow_packages "${specs[@]}"
}

apply_system() { "$DOTFILES_ROOT/platforms/parrot-ctf/scripts/install-system.sh"; }
apply_guest() { "$DOTFILES_ROOT/platforms/parrot-ctf/scripts/install-guest-integration.sh"; }
apply_local() { "$DOTFILES_ROOT/common/setup-local.sh" parrot-ctf "$theme"; }
apply_stow() { "$DOTFILES_ROOT/platforms/parrot-ctf/scripts/stow.sh"; }
apply_terminal() { "$DOTFILES_ROOT/platforms/parrot-ctf/scripts/install-terminal.sh"; }
apply_mise() { "$DOTFILES_ROOT/common/install-mise.sh"; }
apply_nvim() { "$DOTFILES_ROOT/common/install-neovim-tools.sh" --profile parrot-ctf; }
apply_tmux() { "$DOTFILES_ROOT/common/install-tmux-theme.sh"; }
apply_theme() { [[ ! -x "$HOME/.local/bin/theme" ]] || "$HOME/.local/bin/theme" "$theme"; }
verify_parrot() { "$DOTFILES_ROOT/platforms/parrot-ctf/scripts/verify.sh"; }

plan_add system 'Install Parrot-owned working-environment prerequisites' apply preflight_parrot apply_system : 'platforms/parrot-ctf/scripts/install-system.sh; security catalogue unchanged' 'platforms/parrot-ctf/scripts/install-system.sh'
plan_add guest 'Install and activate KVM/QEMU guest integration' apply : apply_guest : 'qemu-guest-agent and SPICE; host secrets and shared folders remain disabled' 'platforms/parrot-ctf/scripts/install-guest-integration.sh'
plan_add local 'Initialize machine-local Git and theme state' apply : apply_local : "common/setup-local.sh parrot-ctf $theme" 'common/setup-local.sh'
plan_add stow 'Deploy the reduced portable and narrow Parrot configuration' apply : apply_stow : 'platforms/parrot-ctf/scripts/stow.sh' 'platforms/parrot-ctf/scripts/stow.sh'
plan_add terminal 'Install the pinned Nerd Font, bat themes, and Konsole profile' apply : apply_terminal : 'platforms/parrot-ctf/scripts/install-terminal.sh' 'platforms/parrot-ctf/scripts/install-terminal.sh'
plan_add mise 'Install the narrow mise-managed uv and Neovim runtimes' apply : apply_mise : 'common/install-mise.sh' 'common/install-mise.sh'
plan_add nvim 'Restore the reduced LazyVim/Mason inventory for Parrot' apply : apply_nvim : 'common/install-neovim-tools.sh --profile parrot-ctf' 'common/install-neovim-tools.sh'
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux : 'common/install-tmux-theme.sh' 'common/install-tmux-theme.sh'
plan_add theme 'Apply the selected theme' apply : apply_theme : "theme $theme" ''
plan_add verify 'Verify the complete Parrot guest' verify : verify_parrot : 'platforms/parrot-ctf/scripts/verify.sh' 'platforms/parrot-ctf/scripts/verify.sh'

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Parrot Security Edition CTF VM plan
-----------------------------------
Theme:                  $theme ($theme_source — $(theme_source_description "$theme_source"))
Hypervisor:             KVM/QEMU through qemu:///system
Normal network:         libvirt default NAT
Security tools:         Existing Parrot/APT catalogue (unchanged)
Python:                 Parrot Python + venv/pipx; never mise-managed
Portable tools:         mise owns uv and pinned Neovim 0.12.5 only
Host secrets:           Not forwarded or mounted
Shared folders:         Disabled unless configured manually
AI tooling:             Not installed
Recorded rerun selection: $install_selection

EOF
  plan_render
  cat <<'EOF'

Excluded: Fedora/DNF/Terra, KDE/Sway, ASUS/ROG, NVIDIA, VM-host, host secret
forwarding, automatic shared folders, offensive-tool package lists, and AI.

No changes were made.
EOF
  exit 0
fi

if [[ "$interactive" == true ]]; then
  printf '\nParrot Security Edition CTF guest installation\n\n'
  printf 'Catppuccin flavour: %s (source: %s — %s)\n' \
    "$theme" "$theme_source" "$(theme_source_description "$theme_source")"
  if confirm "Continue with the isolated lab profile?" y; then :; else
    result=$?; ((result == 1)) || die "Invalid confirmation response"
    printf 'Cancelled; no changes made.\n'; exit 0
  fi
fi

plan_preflight
# Then the network, because a local problem is worth reporting without waiting
# for a probe. The hosts come from config/network-sources.tsv, selected by the
# scripts this resolved plan will run, so a step added later cannot fetch from
# a host nothing checked; scripts/validate-plan-network.py holds the two to
# each other. Nothing has mutated yet at this point.
plan_scripts | preflight_plan_network
DOTFILES_RERUN_COMMAND="$(install_lifecycle_rerun_command parrot-ctf "$install_selection")"
capabilities=''
while IFS= read -r capability; do capabilities+="${capabilities:+,}$capability"; done < <(parrot_selected_capabilities)
install_lifecycle_begin parrot-ctf "$capabilities" "$DOTFILES_RERUN_COMMAND" "$install_selection"
if plan_execute; then :; else
  result=$?
  install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"
  exit "$result"
fi
install_lifecycle_commit

cat <<'EOF'

Parrot CTF guest setup completed. Start a new graphical login session so
Konsole inherits the account's Zsh login shell. Keep challenge state outside
the dotfiles checkout and take a VM snapshot before importing untrusted
material or changing lab networking.
EOF
install_lifecycle_rerun_hint
