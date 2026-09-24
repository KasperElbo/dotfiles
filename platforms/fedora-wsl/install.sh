#!/usr/bin/env bash
set -euo pipefail

# First, before this file sources anything: every line below needs commands a
# minimal Fedora image may not have -- dirname among them -- so the base
# bootstrap installs them before they are used (common/lib/base-bootstrap.sh).
# Through ./install.sh it has already run and finds nothing to do.
install_dir="${BASH_SOURCE[0]%/*}"
[[ "$install_dir" != "${BASH_SOURCE[0]}" ]] || install_dir=.
# shellcheck source=../../common/lib/base-bootstrap.sh
source "$install_dir/../../common/lib/base-bootstrap.sh"
base_bootstrap fedora-wsl "$@"

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
# shellcheck source=lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wsl.sh"
# shellcheck source=lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/containers.sh"
# The --help listing and the --dry-run lines of the persistent options,
# generated from config/install-options.tsv by scripts/render-installer-usage.py
# so a flag the parser accepts cannot go undocumented or be shown mislabelled.
# shellcheck source=lib/usage-options.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/usage-options.sh"

theme="$THEME_DEFAULT_FLAVOUR"; theme_explicit=false
install_ocaml=false; install_latex=false
install_containers=false; containers_api_socket=false; install_ai=false
# Empty means the sub-flag was omitted. install-ai.sh treats that as
# additive -- keep whatever is already installed -- so it must stay
# distinguishable from an explicit --no-<component> removal request.
ai_codex=''; ai_firstmate=''; ai_gnhf=''; ai_backpass=''
interactive=true; dry_run=false; run_dev_workflows=false

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform fedora-wsl [options]

Direct entry point: ./platforms/fedora-wsl/install.sh [options]

Options:
EOF
  usage_persistent_options
  cat <<'EOF'

  AI subcomponents are additive: omitting one leaves it installed.
  --no-<component> is the only thing that removes one, and it confirms first.

Execution controls, for this run only:
  --dev-workflows    Run the disposable development workflow smoke tests
                     (--smoke-test is the deprecated spelling of this)
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Never prompt; resolve every choice from the given
                     options and their defaults. Requires cached sudo
                     (run 'sudo -v' first) where the run needs it.
  -h, --help         Show this help

Desktop, hardware, Tailscale, and VM profiles are intentionally unsupported.
Windows owns terminal behavior and Tailscale for this profile.
EOF
}

while (($#)); do
  case "$1" in
  --theme) [[ $# -ge 2 ]] || die '--theme requires a value'; theme="$2"; theme_explicit=true; shift 2 ;;
  --ocaml) install_ocaml=true; shift ;; --no-ocaml) install_ocaml=false; shift ;;
  --latex) install_latex=true; shift ;; --no-latex) install_latex=false; shift ;;
  --containers) install_containers=true; shift ;; --no-containers) install_containers=false; shift ;;
  --containers-api-socket) containers_api_socket=true; shift ;;
  --ai) install_ai=true; shift ;; --no-ai) install_ai=false; shift ;;
  --codex) ai_codex=true; shift ;; --no-codex) ai_codex=false; shift ;;
  --firstmate) ai_firstmate=true; shift ;; --no-firstmate) ai_firstmate=false; shift ;;
  --gnhf) ai_gnhf=true; shift ;; --no-gnhf) ai_gnhf=false; shift ;;
  --backpass) ai_backpass=true; shift ;; --no-backpass) ai_backpass=false; shift ;;
  --dev-workflows) run_dev_workflows=true; shift ;; --no-dev-workflows) run_dev_workflows=false; shift ;;
  --smoke-test) warn '--smoke-test is deprecated; use --dev-workflows instead.'; run_dev_workflows=true; shift ;;
  --tailscale | --no-tailscale) die '--tailscale is not supported on Fedora WSL: install Tailscale on the Windows host instead.' ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  --rerun) die '--rerun is owned by the root installer: run ./install.sh --rerun instead.' ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option for fedora-wsl: $1" ;;
  esac
done
# An explicit --theme wins; otherwise keep the flavour this machine already
# has, then the one its last successful install recorded, and only then the
# first-install default. A plain rerun must never reset a machine to the
# default (issue #148).
theme_resolve fedora-wsl "$theme_explicit" "$theme"
theme="$THEME_RESOLVED"
theme_source="$THEME_RESOLVED_SOURCE"
[[ "$containers_api_socket" != true || "$install_containers" == true ]] || die '--containers-api-socket requires --containers'
[[ -z "$ai_codex" || "$install_ai" == true ]] || die '--codex/--no-codex requires --ai'
[[ -z "$ai_firstmate" || "$install_ai" == true ]] || die '--firstmate/--no-firstmate requires --ai'
[[ -z "$ai_gnhf" || "$install_ai" == true ]] || die '--gnhf/--no-gnhf requires --ai'
[[ -z "$ai_backpass" || "$install_ai" == true ]] || die '--backpass/--no-backpass requires --ai'

# The resolved persistent configuration of this run; transient controls
# (--dry-run, --non-interactive, --dev-workflows) are deliberately excluded.
install_selection_reset fedora-wsl
install_selection_set theme "$theme"
install_selection_set ocaml "$install_ocaml"
install_selection_set latex "$install_latex"
install_selection_set containers "$install_containers"
install_selection_set containers-api-socket "$containers_api_socket"
install_selection_set ai "$install_ai"
install_selection_set codex "${ai_codex:-inherit}"
install_selection_set firstmate "${ai_firstmate:-inherit}"
install_selection_set gnhf "${ai_gnhf:-inherit}"
install_selection_set backpass "${ai_backpass:-inherit}"
install_selection="$(install_selection_serialize)"
# The command a failed run prints: this selection plus the transient controls
# that add work to this run's plan, because the selection deliberately leaves
# them out and a rerun without them would silently skip that work.
rerun_controls=()
[[ "$run_dev_workflows" != true ]] || rerun_controls+=(--dev-workflows)
DOTFILES_RERUN_COMMAND="$(install_lifecycle_rerun_command fedora-wsl "$install_selection" "${rerun_controls[@]}")"

# The selected capability set is resolved once and reused by the selection
# check, preflight and the lifecycle record, so those three can never disagree.
wsl_selected_capabilities() {
  local selection
  printf '%s\n' base dotnet-debug
  for selection in "$install_ocaml:ocaml" "$install_latex:latex" "$install_containers:containers" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do
    [[ "${selection%%:*}" != true ]] || printf '%s\n' "${selection#*:}"
  done
}
# Checked for every run, --dry-run included: a dry run exits before
# plan_preflight, and it must not show a plan for a capability this platform's
# manifest does not implement.
selected_capabilities=()
while IFS= read -r capability; do selected_capabilities+=("$capability"); done < <(wsl_selected_capabilities)
capability_validate_selection fedora-wsl "${selected_capabilities[@]}" ||
  die 'The selected capabilities cannot be installed on fedora-wsl.'

# Each step's command is stated once, as a repository-relative argument vector
# (see plan_command_run): its apply function runs it and its plan note prints
# it. Invocation-only controls such as --non-interactive stay with apply.
wsl_system_command() { printf '%s\n' platforms/fedora-wsl/scripts/install-system.sh; }
wsl_interop_command() { printf '%s\n' platforms/fedora-wsl/scripts/configure-interop.sh; }
wsl_ocaml_native_command() { printf '%s\n' platforms/fedora/scripts/install-ocaml.sh --wsl; }
wsl_latex_command() { printf '%s\n' platforms/fedora/scripts/install-latex.sh; }
wsl_local_command() { printf '%s\n' common/setup-local.sh fedora-wsl "$theme"; }
wsl_stow_command() { printf '%s\n' platforms/fedora-wsl/scripts/stow.sh; }
wsl_mise_command() { printf '%s\n' common/install-mise.sh; }
wsl_nvim_command() { printf '%s\n' common/install-neovim-tools.sh; }
wsl_ocaml_command() { printf '%s\n' common/install-ocaml.sh; }
wsl_containers_command() { printf '%s\n' platforms/fedora-wsl/scripts/install-containers.sh; [[ "$containers_api_socket" != true ]] || printf '%s\n' --api-socket; }
wsl_tmux_command() { printf '%s\n' common/install-tmux-theme.sh; }
wsl_ai_command() {
  printf '%s\n' common/install-ai.sh
  case "$ai_codex" in true) printf '%s\n' --codex ;; false) printf '%s\n' --no-codex ;; esac
  case "$ai_firstmate" in true) printf '%s\n' --firstmate ;; false) printf '%s\n' --no-firstmate ;; esac
  case "$ai_gnhf" in true) printf '%s\n' --gnhf ;; false) printf '%s\n' --no-gnhf ;; esac
  case "$ai_backpass" in true) printf '%s\n' --backpass ;; false) printf '%s\n' --no-backpass ;; esac
}
wsl_verify_command() { printf '%s\n' platforms/fedora-wsl/scripts/verify.sh; [[ "$run_dev_workflows" != true ]] || printf '%s\n' --dev-workflows; [[ "$install_latex" != true ]] || printf '%s\n' --latex; }

preflight_wsl() {
  # First, and before every other check: an unsupported XDG root would have
  # Stow deploy to a place the rest of the install never reads. It is a pure
  # lexical comparison with no prerequisites, so it really can go first --
  # ahead of preflight_sudo, which prompts for a password on a run that is
  # about to be refused.
  preflight_xdg_layout
  require_regular_user; require_fedora_wsl
  preflight_platform_command_providers fedora-wsl; preflight_sudo "$interactive"
  [[ "$install_containers" != true ]] || require_wsl_containers_prereqs
  preflight_writable_path "$HOME"; preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"; preflight_writable_path "$(profile_state_dir)"
  preflight_disk_space "$XDG_DATA_HOME" "$PREFLIGHT_USER_DATA_MIN_MB"
  preflight_disk_space /var/cache/dnf "$PREFLIGHT_SYSTEM_MIN_MB"
  local specs=() spec capability stow_specs
  local selected=()
  while IFS= read -r capability; do selected+=("$capability"); done < <(wsl_selected_capabilities)
  capability_validate_selection fedora-wsl "${selected[@]}"
  # A checked substitution, not < <(...): a manifest header without the stow
  # column must stop preflight, not silently skip the conflict check.
  stow_specs="$(capability_stow_specs fedora-wsl "${selected[@]}")" || return
  while IFS= read -r spec; do [[ -z "$spec" ]] || specs+=("$spec"); done <<<"$stow_specs"
  preflight_stow_packages "${specs[@]}"
}

apply_system() { plan_command_run wsl_system_command; }
apply_interop() { info 'Ensuring explicit Windows executable interop stays available'; plan_command_run wsl_interop_command; }
apply_ocaml_native() { plan_command_run wsl_ocaml_native_command; }
apply_latex() { plan_command_run wsl_latex_command; }
apply_local() { plan_command_run wsl_local_command; }
apply_stow() { plan_command_run wsl_stow_command; }
apply_mise() { plan_command_run wsl_mise_command; }
apply_nvim() { plan_command_run wsl_nvim_command; }
apply_ocaml() { plan_command_run wsl_ocaml_command; }
apply_containers() { plan_command_run wsl_containers_command; }
apply_tmux() { plan_command_run wsl_tmux_command; }
apply_ai() { local args=(); [[ "$interactive" == true ]] || args+=(--non-interactive); plan_command_run wsl_ai_command "${args[@]}"; }
apply_theme() { theme_apply_stowed "$theme"; }
verify_wsl() { plan_command_run wsl_verify_command; }

plan_add system 'Install Fedora command-line prerequisites and Linux-native mise' apply preflight_wsl apply_system "Set Zsh as the user's default login shell. $(plan_command_note wsl_system_command)" 'platforms/fedora-wsl/scripts/install-system.sh'
plan_add interop 'Preserve explicit Windows executable interop without Windows PATH entries' apply : apply_interop "$(plan_command_note wsl_interop_command); enabled=true, appendWindowsPath=false" 'platforms/fedora-wsl/scripts/configure-interop.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml-native 'Install Fedora OCaml build prerequisites' apply : apply_ocaml_native "$(plan_command_note wsl_ocaml_native_command)" 'platforms/fedora/scripts/install-ocaml.sh'
[[ "$install_latex" != true ]] || plan_add latex 'Install the optional Fedora-owned LaTeX toolchain' apply : apply_latex "$(plan_command_note wsl_latex_command); latexmk, latexindent, Biber" 'platforms/fedora/scripts/install-latex.sh'
plan_add local 'Initialize machine-local Git and theme state' apply : apply_local "$(plan_command_note wsl_local_command)" 'common/setup-local.sh'
plan_add stow 'Deploy portable and Fedora WSL configuration' apply : apply_stow "$(plan_command_note wsl_stow_command)" 'platforms/fedora-wsl/scripts/stow.sh'
plan_add mise 'Install mise-managed Linux runtimes and developer CLIs' apply : apply_mise "$(plan_command_note wsl_mise_command)" 'common/install-mise.sh'
plan_add nvim 'Restore LazyVim and install the Mason inventory' apply : apply_nvim "$(plan_command_note wsl_nvim_command)" 'common/install-neovim-tools.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml 'Create the opam-owned OCaml switch' apply : apply_ocaml "$(plan_command_note wsl_ocaml_command)" 'common/install-ocaml.sh'
[[ "$install_containers" != true ]] || plan_add containers 'Install the optional rootless Podman profile' apply : apply_containers "$(plan_command_note wsl_containers_command)" 'platforms/fedora-wsl/scripts/install-containers.sh'
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux "$(plan_command_note wsl_tmux_command)" 'common/install-tmux-theme.sh'
[[ "$install_ai" != true ]] || plan_add ai 'Install the optional AI-assisted development profile' apply : apply_ai "$(plan_command_note wsl_ai_command)" 'common/install-ai.sh'
plan_add theme 'Apply the selected theme' apply : apply_theme "theme $theme" ''
plan_add verify 'Verify WSL detection, Linux command ownership, and runtime startup' verify : verify_wsl "$(plan_command_note wsl_verify_command)" 'platforms/fedora-wsl/scripts/verify.sh'

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Fedora WSL installation plan
----------------------------
EOF
  plan_persistent_options
  cat <<EOF
Flavour source:      $theme_source — $(theme_source_description "$theme_source")
Development workflow smoke tests: $run_dev_workflows  (this run only)
Recorded rerun selection: $install_selection
Rerun if this run fails: $DOTFILES_RERUN_COMMAND

EOF
  plan_render
  cat <<'EOF'

Excluded: KDE, Sway, Ghostty, ASUS/ROG, NVIDIA, VM host/guest, and desktop.
The AI profile has no GUI or hardware dependency.

No changes were made.
EOF
  exit 0
fi

if [[ "$interactive" == true ]]; then
  printf '\nFedora WSL workstation installation\n\n'
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
while IFS= read -r capability; do capabilities+="${capabilities:+,}$capability"; done < <(wsl_selected_capabilities)
install_lifecycle_begin fedora-wsl "$capabilities" "$DOTFILES_RERUN_COMMAND" "$install_selection"
if plan_execute; then :; else
  result=$?; install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"; exit "$result"
fi
install_lifecycle_commit
# Backticks are documentation, not command substitution.
# shellcheck disable=SC2016
printf '\nFedora WSL setup completed. Run `exec zsh -l` for the new shell.\n'
install_lifecycle_rerun_hint
