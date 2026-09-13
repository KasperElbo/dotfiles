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
# shellcheck source=lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wsl.sh"
# shellcheck source=lib/containers.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/containers.sh"

theme=macchiato; install_ocaml=false; install_latex=false
install_containers=false; containers_api_socket=false; install_ai=false
ai_codex=false; ai_firstmate=false; ai_gnhf=false; ai_backpass=false
interactive=true; dry_run=false; run_smoke_tests=false

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform fedora-wsl [options]

Direct entry point: ./platforms/fedora-wsl/install.sh [options]

Options:
  --theme FLAVOUR    latte, frappe, macchiato, or mocha (default: macchiato)
  --ocaml/--no-ocaml
  --latex/--no-latex
  --containers/--no-containers
  --containers-api-socket
  --ai/--no-ai       Optional Claude Code and Herdr profile
  --codex/--no-codex, --firstmate/--no-firstmate
  --gnhf/--no-gnhf, --backpass/--no-backpass
  --smoke-test
  --dry-run          Show the resolved plan without changing anything
  --non-interactive  Use defaults without prompting (requires cached sudo)
  -h, --help         Show this help

Desktop, hardware, Tailscale, and VM profiles are intentionally unsupported.
Windows owns terminal behavior and Tailscale for this profile.
EOF
}

while (($#)); do
  case "$1" in
  --theme) [[ $# -ge 2 ]] || die '--theme requires a value'; theme="$2"; shift 2 ;;
  --ocaml) install_ocaml=true; shift ;; --no-ocaml) install_ocaml=false; shift ;;
  --latex) install_latex=true; shift ;; --no-latex) install_latex=false; shift ;;
  --containers) install_containers=true; shift ;; --no-containers) install_containers=false; shift ;;
  --containers-api-socket) containers_api_socket=true; shift ;;
  --ai) install_ai=true; shift ;; --no-ai) install_ai=false; shift ;;
  --codex) ai_codex=true; shift ;; --no-codex) ai_codex=false; shift ;;
  --firstmate) ai_firstmate=true; shift ;; --no-firstmate) ai_firstmate=false; shift ;;
  --gnhf) ai_gnhf=true; shift ;; --no-gnhf) ai_gnhf=false; shift ;;
  --backpass) ai_backpass=true; shift ;; --no-backpass) ai_backpass=false; shift ;;
  --smoke-test) run_smoke_tests=true; shift ;;
  --tailscale | --no-tailscale) die '--tailscale is not supported on Fedora WSL: install Tailscale on the Windows host instead.' ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option for fedora-wsl: $1" ;;
  esac
done
case "$theme" in latte | frappe | macchiato | mocha) ;; *) die "Invalid Catppuccin flavour: $theme" ;; esac
[[ "$containers_api_socket" != true || "$install_containers" == true ]] || die '--containers-api-socket requires --containers'
[[ "$ai_codex" != true || "$install_ai" == true ]] || die '--codex requires --ai'
[[ "$ai_firstmate" != true || "$install_ai" == true ]] || die '--firstmate requires --ai'
[[ "$ai_gnhf" != true || "$install_ai" == true ]] || die '--gnhf requires --ai'
[[ "$ai_backpass" != true || "$install_ai" == true ]] || die '--backpass requires --ai'

preflight_wsl() {
  require_regular_user; require_fedora_wsl
  preflight_commands awk date dnf find git readlink sudo; preflight_sudo "$interactive"
  [[ "$install_containers" != true ]] || require_wsl_containers_prereqs
  preflight_writable_path "$HOME"; preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"; preflight_writable_path "$(profile_state_dir)"
  local specs=() spec
  local selected=(base)
  for selection in "$install_ocaml:ocaml" "$install_latex:latex" "$install_containers:containers" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do
    [[ "${selection%%:*}" != true ]] || selected+=("${selection#*:}")
  done
  capability_validate_selection fedora-wsl "${selected[@]}"
  while IFS= read -r spec; do specs+=("$spec"); done < <(capability_stow_specs fedora-wsl "${selected[@]}")
  preflight_stow_packages "${specs[@]}"
}

apply_system() { "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/install-system.sh"; }
apply_interop() { "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/configure-interop.sh"; }
apply_ocaml_native() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-ocaml.sh" --wsl; }
apply_latex() { "$DOTFILES_ROOT/platforms/fedora/scripts/install-latex.sh"; }
apply_local() { "$DOTFILES_ROOT/common/setup-local.sh" "$theme"; }
apply_stow() { "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/stow.sh"; }
apply_mise() { "$DOTFILES_ROOT/common/install-mise.sh"; }
apply_nvim() { "$DOTFILES_ROOT/common/install-neovim-tools.sh"; }
apply_ocaml() { "$DOTFILES_ROOT/common/install-ocaml.sh"; }
apply_containers() { local args=(); [[ "$containers_api_socket" != true ]] || args+=(--api-socket); "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/install-containers.sh" "${args[@]}"; }
apply_tmux() { "$DOTFILES_ROOT/common/install-tmux-theme.sh"; }
apply_ai() { local args=(); [[ "$ai_codex" != true ]] || args+=(--codex); [[ "$ai_firstmate" != true ]] || args+=(--firstmate); [[ "$ai_gnhf" != true ]] || args+=(--gnhf); [[ "$ai_backpass" != true ]] || args+=(--backpass); "$DOTFILES_ROOT/common/install-ai.sh" "${args[@]}"; }
apply_theme() { [[ ! -x "$HOME/.local/bin/theme" ]] || "$HOME/.local/bin/theme" "$theme"; }
verify_wsl() { local args=(); [[ "$run_smoke_tests" != true ]] || args+=(--smoke-test); [[ "$install_latex" != true ]] || args+=(--latex); "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/verify.sh" "${args[@]}"; }

plan_add system 'Install Fedora command-line prerequisites and Linux-native mise' apply preflight_wsl apply_system : "Set Zsh as the user's default login shell. platforms/fedora-wsl/scripts/install-system.sh"
plan_add interop 'Preserve explicit Windows executable interop without Windows PATH entries' apply : apply_interop : 'platforms/fedora-wsl/scripts/configure-interop.sh; enabled=true, appendWindowsPath=false'
[[ "$install_ocaml" != true ]] || plan_add ocaml-native 'Install Fedora OCaml build prerequisites' apply : apply_ocaml_native : 'platforms/fedora/scripts/install-ocaml.sh --wsl'
[[ "$install_latex" != true ]] || plan_add latex 'Install the optional Fedora-owned LaTeX toolchain' apply : apply_latex : 'platforms/fedora/scripts/install-latex.sh; latexmk, latexindent, Biber'
plan_add local 'Initialize machine-local Git and theme state' apply : apply_local : "common/setup-local.sh $theme"
plan_add stow 'Deploy portable and Fedora WSL configuration' apply : apply_stow : 'platforms/fedora-wsl/scripts/stow.sh'
plan_add mise 'Install mise-managed Linux runtimes and developer CLIs' apply : apply_mise : 'common/install-mise.sh'
plan_add nvim 'Restore LazyVim and install the Mason inventory' apply : apply_nvim : 'common/install-neovim-tools.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml 'Create the opam-owned OCaml switch' apply : apply_ocaml : 'common/install-ocaml.sh'
if [[ "$install_containers" == true ]]; then
  container_note='platforms/fedora-wsl/scripts/install-containers.sh'
  [[ "$containers_api_socket" != true ]] || container_note+=' --api-socket'
  plan_add containers 'Install the optional rootless Podman profile' apply : apply_containers : "$container_note"
fi
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux : 'common/install-tmux-theme.sh'
if [[ "$install_ai" == true ]]; then
  ai_note='common/install-ai.sh'; [[ "$ai_codex" != true ]] || ai_note+=' --codex'; [[ "$ai_firstmate" != true ]] || ai_note+=' --firstmate'; [[ "$ai_gnhf" != true ]] || ai_note+=' --gnhf'; [[ "$ai_backpass" != true ]] || ai_note+=' --backpass'
  plan_add ai 'Install the optional AI-assisted development profile' apply : apply_ai : "$ai_note"
fi
plan_add theme 'Apply the selected theme' apply : apply_theme : "theme $theme"
verify_note='platforms/fedora-wsl/scripts/verify.sh'; [[ "$run_smoke_tests" != true ]] || verify_note+=' --smoke-test'; [[ "$install_latex" != true ]] || verify_note+=' --latex'
plan_add verify 'Verify WSL detection, Linux command ownership, and runtime startup' verify : verify_wsl : "$verify_note"

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Fedora WSL installation plan
----------------------------
Catppuccin flavour: $theme
OCaml profile:      $install_ocaml
LaTeX toolchain:    $install_latex
Containers profile: $install_containers
Containers API socket: $containers_api_socket
AI profile:         $install_ai
AI Codex subcomponent:     $ai_codex
AI FirstMate subcomponent: $ai_firstmate
AI GNHF subcomponent:      $ai_gnhf
AI backpass subcomponent:  $ai_backpass
Workflow smoke test: $run_smoke_tests

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
  if confirm 'Continue with installation?' y; then :; else
    result=$?; ((result == 1)) || die 'Invalid confirmation response'; printf 'Cancelled; no changes made.\n'; exit 0
  fi
fi
plan_preflight
capabilities=base
for selection in "$install_ocaml:ocaml" "$install_latex:latex" "$install_containers:containers" "$install_ai:ai" "$ai_codex:codex" "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do [[ "${selection%%:*}" != true ]] || capabilities+=,"${selection#*:}"; done
DOTFILES_RERUN_COMMAND='./install.sh --platform fedora-wsl --non-interactive'
install_lifecycle_begin fedora-wsl "$capabilities" "$DOTFILES_RERUN_COMMAND"
if plan_execute; then :; else
  result=$?; install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"; exit "$result"
fi
install_lifecycle_commit
# Backticks are documentation, not command substitution.
# shellcheck disable=SC2016
printf '\nFedora WSL setup completed. Run `exec zsh -l` for the new shell.\n'
