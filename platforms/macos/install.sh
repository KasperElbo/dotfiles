#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  printf 'ERROR: The macOS installer requires Bash 4.4 or newer. Start it through ./install.sh --platform macos.\n' >&2
  exit 2
fi

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
# shellcheck source=lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/macos.sh"
# shellcheck source=lib/install-actions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/install-actions.sh"

theme="$THEME_DEFAULT_FLAVOUR"; theme_explicit=false; install_ocaml=false; install_containers=false
install_tailscale=false; apply_defaults=true; run_dev_workflows=false
install_ai=false
# Empty means the sub-flag was omitted. common/install-ai.sh treats that as
# additive -- keep whatever is already installed -- so it must stay
# distinguishable from an explicit --no-<component> removal request.
ai_codex=''; ai_firstmate=''; ai_gnhf=''; ai_backpass=''
interactive=true; dry_run=false

usage() {
  cat "$(dirname "${BASH_SOURCE[0]}")/bootstrap-help.txt"
  printf '\nDirect entry point (modern Bash only): ./platforms/macos/install.sh [options]\n'
}

while (($#)); do
  case "$1" in
  --theme) [[ $# -ge 2 ]] || die "--theme requires a value"; theme="$2"; theme_explicit=true; shift 2 ;;
  --ocaml) install_ocaml=true; shift ;; --no-ocaml) install_ocaml=false; shift ;;
  --containers) install_containers=true; shift ;; --no-containers) install_containers=false; shift ;;
  --tailscale) install_tailscale=true; shift ;; --no-tailscale) install_tailscale=false; shift ;;
  --defaults) apply_defaults=true; shift ;; --no-defaults) apply_defaults=false; shift ;;
  --dev-workflows) run_dev_workflows=true; shift ;; --no-dev-workflows) run_dev_workflows=false; shift ;;
  --ai) install_ai=true; shift ;; --no-ai) install_ai=false; shift ;;
  --codex) ai_codex=true; shift ;; --no-codex) ai_codex=false; shift ;;
  --firstmate) ai_firstmate=true; shift ;; --no-firstmate) ai_firstmate=false; shift ;;
  --gnhf) ai_gnhf=true; shift ;; --no-gnhf) ai_gnhf=false; shift ;;
  --backpass) ai_backpass=true; shift ;; --no-backpass) ai_backpass=false; shift ;;
  --workflows) warn '--workflows is deprecated; use --dev-workflows instead.'; run_dev_workflows=true; shift ;;
  --no-workflows) warn '--no-workflows is deprecated; use --no-dev-workflows instead.'; run_dev_workflows=false; shift ;;
  --latex | --no-latex)
    die "$1 is not a macOS option: this installer owns no TeX distribution.
TeX is externally managed on macOS -- install MacTeX or BasicTeX yourself.
See docs/macos.md, 'LaTeX is externally managed on macOS'."
    ;;
  --dry-run) dry_run=true; interactive=false; shift ;;
  --non-interactive) interactive=false; shift ;;
  --rerun) die '--rerun is owned by the root installer: run ./install.sh --rerun instead.' ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option for macos: $1" ;;
  esac
done
# An explicit --theme wins; otherwise keep the flavour this machine already
# has, then the one its last successful install recorded, and only then the
# first-install default. A plain rerun must never reset a machine to the
# default (issue #148).
theme_resolve macos "$theme_explicit" "$theme"
theme="$THEME_RESOLVED"
theme_source="$THEME_RESOLVED_SOURCE"
[[ -z "$ai_codex" || "$install_ai" == true ]] || die '--codex/--no-codex requires --ai'
[[ -z "$ai_firstmate" || "$install_ai" == true ]] || die '--firstmate/--no-firstmate requires --ai'
[[ -z "$ai_gnhf" || "$install_ai" == true ]] || die '--gnhf/--no-gnhf requires --ai'
[[ -z "$ai_backpass" || "$install_ai" == true ]] || die '--backpass/--no-backpass requires --ai'

# One unsupported optional component must reject exactly its own sub-flag, not
# the whole AI profile. The capability manifest is the authority on what this
# platform actually implements, so a component demoted there stops being
# installable here without any second list to keep in sync. A --no-<component>
# removal stays available regardless, so an unsupported component can still be
# cleaned up.
macos_require_implemented_capability() {
  local flag="$1" capability="$2" status
  status="$(capability_field macos "$capability" status 2>/dev/null || printf 'undeclared')"
  [[ "$status" != implemented ]] || return 0
  die "$flag is not supported on Apple Silicon macOS.
config/capabilities.tsv declares the '$capability' capability '$status' for
macos, and this installer will not pretend to install it. The rest of the AI
profile is unaffected: rerun without $flag.
See docs/macos.md, 'AI-assisted development toolchain'."
}
if [[ "$install_ai" == true ]]; then
  macos_require_implemented_capability --ai ai
  [[ "$ai_codex" != true ]] || macos_require_implemented_capability --codex codex
  [[ "$ai_firstmate" != true ]] || macos_require_implemented_capability --firstmate firstmate
  [[ "$ai_gnhf" != true ]] || macos_require_implemented_capability --gnhf gnhf
  [[ "$ai_backpass" != true ]] || macos_require_implemented_capability --backpass backpass
fi

# The selected capability set is resolved once and reused by preflight, the
# lifecycle record, and the rerun hint, so those three can never disagree.
macos_selected_capabilities() {
  local selection
  printf '%s\n' base dotnet-debug
  for selection in "$install_ocaml:ocaml" "$install_containers:containers" \
    "$install_tailscale:tailscale" "$install_ai:ai" "$ai_codex:codex" \
    "$ai_firstmate:firstmate" "$ai_gnhf:gnhf" "$ai_backpass:backpass"; do
    [[ "${selection%%:*}" != true ]] || printf '%s\n' "${selection#*:}"
  done
}

# The note the plan and dry-run show for the AI step, and the exact argument
# vector apply_ai passes, are built from one function so a dry-run can never
# describe a different command than the one that runs.
macos_ai_args() {
  case "$ai_codex" in true) printf '%s\n' --codex ;; false) printf '%s\n' --no-codex ;; esac
  case "$ai_firstmate" in true) printf '%s\n' --firstmate ;; false) printf '%s\n' --no-firstmate ;; esac
  case "$ai_gnhf" in true) printf '%s\n' --gnhf ;; false) printf '%s\n' --no-gnhf ;; esac
  case "$ai_backpass" in true) printf '%s\n' --backpass ;; false) printf '%s\n' --no-backpass ;; esac
}

# The resolved persistent configuration of this run; transient controls
# (--dry-run, --non-interactive, --dev-workflows) are deliberately excluded.
install_selection_reset macos
install_selection_set theme "$theme"
install_selection_set ocaml "$install_ocaml"
install_selection_set containers "$install_containers"
install_selection_set tailscale "$install_tailscale"
install_selection_set defaults "$apply_defaults"
install_selection_set ai "$install_ai"
# Tristates: an omitted AI sub-flag is remembered as "inherit", so a rerun
# reproduces the additive request the user actually made rather than hardening
# it into an install or a removal.
install_selection_set codex "${ai_codex:-inherit}"
install_selection_set firstmate "${ai_firstmate:-inherit}"
install_selection_set gnhf "${ai_gnhf:-inherit}"
install_selection_set backpass "${ai_backpass:-inherit}"
install_selection="$(install_selection_serialize)"

preflight_macos() {
  require_regular_user
  require_apple_silicon_macos
  preflight_commands awk date find git readlink xcode-select
  xcode-select -p >/dev/null 2>&1 || die "Apple Command Line Tools are required; run 'xcode-select --install'."
  if [[ ! -x "$(homebrew_path)" ]]; then
    preflight_commands curl sudo
    preflight_sudo "$interactive"
  fi
  preflight_writable_path "$HOME"; preflight_writable_path "$XDG_CONFIG_HOME"
  preflight_writable_path "$XDG_DATA_HOME"; preflight_writable_path "$(profile_state_dir)"
  local specs=() spec capability
  local selected=()
  while IFS= read -r capability; do selected+=("$capability"); done < <(macos_selected_capabilities)
  capability_validate_selection macos "${selected[@]}"
  while IFS= read -r spec; do specs+=("$spec"); done < <(capability_stow_specs macos "${selected[@]}")
  preflight_stow_packages "${specs[@]}"
}

apply_system() {
  macos_run_system_installer "$interactive"
}
apply_ocaml_native() { "$DOTFILES_ROOT/platforms/macos/scripts/install-ocaml.sh"; }
apply_containers() { "$DOTFILES_ROOT/platforms/macos/scripts/install-containers.sh"; }
apply_tailscale() { "$DOTFILES_ROOT/platforms/macos/scripts/install-tailscale.sh"; }
apply_local() { "$DOTFILES_ROOT/common/setup-local.sh" "$theme"; }
apply_stow() { "$DOTFILES_ROOT/platforms/macos/scripts/stow.sh"; }
apply_mise() { "$DOTFILES_ROOT/common/install-mise.sh"; }
apply_nvim() { "$DOTFILES_ROOT/common/install-neovim-tools.sh"; }
apply_tmux() { "$DOTFILES_ROOT/common/install-tmux-theme.sh"; }
apply_ocaml() { "$DOTFILES_ROOT/common/install-ocaml.sh"; }
apply_ai() {
  local args=() argument
  while IFS= read -r argument; do args+=("$argument"); done < <(macos_ai_args)
  [[ "$interactive" == true ]] || args+=(--non-interactive)
  "$DOTFILES_ROOT/common/install-ai.sh" "${args[@]}"
}
apply_macos_defaults() { "$DOTFILES_ROOT/platforms/macos/scripts/apply-defaults.sh"; }
apply_dev_workflows() { local args=(--all); [[ "$install_ocaml" != true ]] || args+=(--ocaml); "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" "${args[@]}"; }
apply_theme() { [[ ! -x "$HOME/.local/bin/theme" ]] || "$HOME/.local/bin/theme" "$theme"; }
apply_aerospace() { open -a AeroSpace || warn 'Open AeroSpace manually from /Applications'; }
verify_macos() {
  macos_run_verifier "$apply_defaults" "$install_containers" "$install_tailscale"
}

plan_add system 'Verify native arm64 macOS and install the Homebrew baseline' apply preflight_macos apply_system : 'Install native Homebrew at /opt/homebrew, Brewfile machine tools, Ghostty, and AeroSpace. Sets a registered Zsh as the login shell when the account does not already use one.'
[[ "$install_ocaml" != true ]] || plan_add ocaml-native 'Install Homebrew OCaml prerequisites' apply : apply_ocaml_native : 'platforms/macos/scripts/install-ocaml.sh'
[[ "$install_containers" != true ]] || plan_add containers 'Install and start a rootless Podman machine' apply : apply_containers : 'Run an ARM64 smoke test with the Podman machine.'
[[ "$install_tailscale" != true ]] || plan_add tailscale 'Install the optional Tailscale profile (Homebrew cask, interactive login).' apply : apply_tailscale : 'Authentication and Network Extension approval remain interactive.'
plan_add local 'Initialize local Git and theme state' apply : apply_local : "common/setup-local.sh $theme"
plan_add stow 'Deploy shared and macOS configuration' apply : apply_stow : 'platforms/macos/scripts/stow.sh'
plan_add mise 'Install mise-managed runtimes' apply : apply_mise : 'common/install-mise.sh'
plan_add nvim 'Restore LazyVim and Mason tools' apply : apply_nvim : 'common/install-neovim-tools.sh'
plan_add tmux 'Install the pinned Catppuccin tmux theme' apply : apply_tmux : 'common/install-tmux-theme.sh'
[[ "$install_ocaml" != true ]] || plan_add ocaml 'Create the opam-owned OCaml switch and platform tools' apply : apply_ocaml : 'common/install-ocaml.sh'
if [[ "$install_ai" == true ]]; then
  # After mise: the shared installer resolves every AI tool through the mise
  # environment this platform has just activated, so macOS adds no Homebrew or
  # global-npm copy of anything.
  ai_note='common/install-ai.sh'
  while IFS= read -r ai_argument; do ai_note+=" $ai_argument"; done < <(macos_ai_args)
  plan_add ai 'Install the optional AI-assisted development profile' apply : apply_ai : "$ai_note"
fi
[[ "$apply_defaults" != true ]] || plan_add defaults 'Apply reversible Dock, Finder, screenshot, keyboard, and Mission Control defaults' apply : apply_macos_defaults : 'platforms/macos/scripts/apply-defaults.sh'
if [[ "$run_dev_workflows" == true ]]; then
  dev_workflows_note='scripts/test-dev-workflows.sh --all'; [[ "$install_ocaml" != true ]] || dev_workflows_note+=' --ocaml'
  plan_add dev-workflows 'Run the disposable development workflow smoke tests' verify : apply_dev_workflows : "$dev_workflows_note"
fi
plan_add theme 'Apply the selected theme' apply : apply_theme : "theme $theme"
plan_add aerospace 'Launch AeroSpace' apply : apply_aerospace : 'macOS may request Accessibility access.'
plan_add verify 'Verify installation and native architecture' verify : verify_macos : 'platforms/macos/scripts/verify.sh'

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Apple Silicon macOS installation plan
--------------------------------------
Catppuccin flavour: $theme  (source: $theme_source — $(theme_source_description "$theme_source"))
Window manager:     AeroSpace (Sway-compatible nine-workspace profile)
macOS defaults:     $apply_defaults
OCaml profile:      $install_ocaml
Containers profile: $install_containers
Tailscale profile:  $install_tailscale
Development workflow smoke tests: $run_dev_workflows  (this run only)
AI tooling profile: $install_ai
AI Codex subcomponent:     ${ai_codex:-inherit}
AI FirstMate subcomponent: ${ai_firstmate:-inherit}
AI GNHF subcomponent:      ${ai_gnhf:-inherit}
AI backpass subcomponent:  ${ai_backpass:-inherit}
Recorded rerun selection: $install_selection

EOF
  plan_render
  printf '\nNo changes were made.\n\n'; exit 0
fi

if [[ "$interactive" == true ]]; then
  printf '\nApple Silicon macOS workstation\n\n'
  printf 'Catppuccin flavour: %s (source: %s — %s)\n' \
    "$theme" "$theme_source" "$(theme_source_description "$theme_source")"
  if confirm 'Continue with installation?' y; then :; else
    result=$?; ((result == 1)) || die 'Invalid confirmation response'
    printf 'Cancelled; no changes made.\n'; exit 0
  fi
fi
plan_preflight
capabilities=''
while IFS= read -r capability; do capabilities+="${capabilities:+,}$capability"; done < <(macos_selected_capabilities)
DOTFILES_RERUN_COMMAND="$(install_lifecycle_rerun_command macos "$install_selection")"
install_lifecycle_begin macos "$capabilities" "$DOTFILES_RERUN_COMMAND" "$install_selection"
if plan_execute; then :; else
  result=$?; install_lifecycle_failed "${PLAN_IDS[PLAN_CURRENT_INDEX]}" "$(plan_completed_ids)" "$(plan_pending_ids "$((PLAN_CURRENT_INDEX + 1))")"; exit "$result"
fi
install_lifecycle_commit

cat <<'EOF'

Finish the manual security and display steps in docs/macos.md. Grant AeroSpace
Accessibility access, keep SIP and Gatekeeper enabled, and configure Git/SSH.
EOF
install_lifecycle_rerun_hint
