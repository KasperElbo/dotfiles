#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
# shellcheck source=lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/macos.sh"

theme="macchiato"
install_ocaml="false"
install_containers="false"
apply_defaults="true"
run_workflows="false"
interactive="true"
dry_run="false"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --theme FLAVOUR    latte, frappe, macchiato, or mocha (default: macchiato)
  --ocaml            Install the optional opam-managed OCaml profile
  --no-ocaml         Do not install OCaml (default)
  --containers       Install the optional rootless Podman machine profile
  --no-containers    Do not install containers (default)
  --defaults         Apply the documented, conservative macOS defaults (default)
  --no-defaults      Leave macOS defaults unchanged
  --workflows        Run disposable .NET, Angular, and Python workflow tests
  --no-workflows     Skip network-dependent workflow tests (default)
  --dry-run          Show the complete plan without changing anything
  --non-interactive  Use selected options without prompting
  -h, --help         Show this help
EOF
}

while (($#)); do
  case "$1" in
  --theme)
    [[ $# -ge 2 ]] || die "--theme requires a value"
    theme="$2"
    shift 2
    ;;
  --ocaml) install_ocaml="true"; shift ;;
  --no-ocaml) install_ocaml="false"; shift ;;
  --containers) install_containers="true"; shift ;;
  --no-containers) install_containers="false"; shift ;;
  --defaults) apply_defaults="true"; shift ;;
  --no-defaults) apply_defaults="false"; shift ;;
  --workflows) run_workflows="true"; shift ;;
  --no-workflows) run_workflows="false"; shift ;;
  --dry-run) dry_run="true"; interactive="false"; shift ;;
  --non-interactive) interactive="false"; shift ;;
  -h | --help) usage; exit 0 ;;
  *) die "Unknown option: $1" ;;
  esac
done

case "$theme" in
latte | frappe | macchiato | mocha) ;;
*) die "Invalid Catppuccin flavour: $theme" ;;
esac

if [[ "$dry_run" == true ]]; then
  cat <<EOF

Apple Silicon macOS installation plan
--------------------------------------

Catppuccin flavour: $theme
Window manager:     AeroSpace (Sway-compatible nine-workspace profile)
macOS defaults:     $apply_defaults
OCaml profile:      $install_ocaml
Containers profile: $install_containers
Development tests:  $run_workflows
AI tooling profile: unavailable until repository issue #16 lands

Steps:

  1. Verify native arm64 macOS and Apple Command Line Tools.
  2. Install native Homebrew at /opt/homebrew when absent.
  3. Install Brewfile machine tools, Ghostty, and AeroSpace.
EOF
  step=4
  if [[ "$install_ocaml" == true ]]; then
    printf '  %d. Install Homebrew OCaml prerequisites.\n' "$step"
    step=$((step + 1))
  fi
  if [[ "$install_containers" == true ]]; then
    printf '  %d. Install and start a rootless Podman machine; run an ARM64 smoke test.\n' "$step"
    step=$((step + 1))
  fi
  cat <<EOF
  $step. Initialize local Git/theme state and stow shared plus macOS configuration.
  $((step + 1)). Install mise runtimes, LazyVim/Mason tools, and Catppuccin tmux.
EOF
  step=$((step + 2))
  if [[ "$install_ocaml" == true ]]; then
    printf '  %d. Create the opam-owned OCaml switch and platform tools.\n' "$step"
    step=$((step + 1))
  fi
  if [[ "$apply_defaults" == true ]]; then
    printf '  %d. Apply reversible Dock, Finder, screenshot, keyboard, and Mission Control defaults.\n' "$step"
    step=$((step + 1))
  fi
  if [[ "$run_workflows" == true ]]; then
    printf '  %d. Run disposable .NET, Angular, and Python end-to-end tests.\n' "$step"
    step=$((step + 1))
  fi
  cat <<EOF
  $step. Launch AeroSpace, then verify installation and native architecture.

Manual configuration still required afterward:

  • Grant AeroSpace Accessibility permission in Privacy & Security.
  • Choose the documented Mission Control multi-display setting.
  • Configure Git identity and SSH authentication; run gh auth login.
  • Review keyboard, trackpad, Touch ID, FileVault, and application permissions.

No changes were made.

EOF
  exit 0
fi

require_apple_silicon_macos

if [[ "$interactive" == true ]]; then
  printf '\nApple Silicon macOS workstation\n'
  printf '%s\n' '---------------------------------'
  printf 'Theme:       %s\n' "$theme"
  printf 'AeroSpace:   enabled (Sway-compatible profile)\n'
  printf 'Defaults:    %s\n' "$apply_defaults"
  printf 'OCaml:       %s\n' "$install_ocaml"
  printf 'Containers:  %s\n\n' "$install_containers"
  printf 'Workflows:   %s\n\n' "$run_workflows"
  confirm "Continue with installation?" "y" || exit 0
fi

system_args=()
[[ "$interactive" == true ]] || system_args+=(--non-interactive)
"$DOTFILES_ROOT/platforms/macos/scripts/install-system.sh" "${system_args[@]}"
activate_homebrew_path

if [[ "$install_ocaml" == true ]]; then
  "$DOTFILES_ROOT/platforms/macos/scripts/install-ocaml.sh"
fi
if [[ "$install_containers" == true ]]; then
  "$DOTFILES_ROOT/platforms/macos/scripts/install-containers.sh"
fi

"$DOTFILES_ROOT/common/setup-local.sh" "$theme"
"$DOTFILES_ROOT/platforms/macos/scripts/stow.sh"
"$DOTFILES_ROOT/common/install-mise.sh"
"$DOTFILES_ROOT/common/install-neovim-tools.sh"
"$DOTFILES_ROOT/common/install-tmux-theme.sh"

if [[ "$install_ocaml" == true ]]; then
  "$DOTFILES_ROOT/common/install-ocaml.sh"
fi

if [[ "$apply_defaults" == true ]]; then
  "$DOTFILES_ROOT/platforms/macos/scripts/apply-defaults.sh"
fi

if [[ "$run_workflows" == true ]]; then
  "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --all
  if [[ "$install_ocaml" == true ]]; then
    "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --ocaml
  fi
fi

theme_command="$HOME/.local/bin/theme"
[[ ! -x "$theme_command" ]] || "$theme_command" "$theme"

info "Opening AeroSpace so macOS can request Accessibility access"
open -a AeroSpace || warn "Open AeroSpace manually from /Applications"

verify_args=()
[[ "$apply_defaults" != true ]] || verify_args+=(--defaults)
[[ "$install_containers" != true ]] || verify_args+=(--containers)

printf '\n'
if "$DOTFILES_ROOT/platforms/macos/scripts/verify.sh" "${verify_args[@]}"; then
  success "macOS workstation installation completed"
else
  warn "Installation completed, but verification reported failures"
  exit 1
fi

cat <<'EOF'

Finish the manual security and display steps in docs/macos.md. In particular,
grant AeroSpace Accessibility access, keep SIP and Gatekeeper enabled, and do
not enable Rosetta for Ghostty. Configure Git/SSH identities and run gh auth
login before using repository workflows.

EOF
