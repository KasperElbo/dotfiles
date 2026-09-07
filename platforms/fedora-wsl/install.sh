#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
# shellcheck source=lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wsl.sh"

theme="macchiato"
install_ocaml="false"
interactive="true"
dry_run="false"
run_smoke_tests="false"

usage() {
  cat <<'EOF'
Usage: ./install.sh --platform fedora-wsl [options]

Options:
  --theme FLAVOUR    Catppuccin flavour:
                     latte, frappe, macchiato, mocha
                     Default: macchiato

  --ocaml            Install the optional OCaml development profile
  --no-ocaml         Do not install the OCaml profile (default)

  --smoke-test       Run representative development workflow tests after setup
  --dry-run          Show the installation plan without changing anything
  --non-interactive  Use defaults without prompting

  -h, --help         Show this help

Desktop, hardware, VM-host/guest, LaTeX and AI profiles are not part of the
Fedora WSL workstation variant.
EOF
}

while (($#)); do
  case "$1" in
  --theme)
    [[ $# -ge 2 ]] || die "--theme requires a value"
    theme="$2"
    shift 2
    ;;
  --ocaml)
    install_ocaml="true"
    shift
    ;;
  --no-ocaml)
    install_ocaml="false"
    shift
    ;;
  --smoke-test)
    run_smoke_tests="true"
    shift
    ;;
  --dry-run)
    dry_run="true"
    interactive="false"
    shift
    ;;
  --non-interactive)
    interactive="false"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option for fedora-wsl: $1"
    ;;
  esac
done

case "$theme" in
latte | frappe | macchiato | mocha) ;;
*) die "Invalid Catppuccin flavour: $theme" ;;
esac

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Fedora WSL installation plan
----------------------------

Catppuccin flavour: $theme
OCaml profile:      $install_ocaml
Workflow smoke test: $run_smoke_tests

Steps:

  1. Validate that this is the official Fedora distribution running in WSL.

  2. Install Fedora command-line prerequisites and Linux-native mise.
     Set Zsh as the user's default login shell.
     platforms/fedora-wsl/scripts/install-system.sh

  3. Initialize machine-local Git and theme state.
     common/setup-local.sh $theme

  4. Deploy portable configuration without Linux GUI/terminal files, then add
     the Fedora WSL PATH, clipboard, URL-opening and Neovim integration.
     platforms/fedora-wsl/scripts/stow.sh

  5. Install mise-managed Linux runtimes and developer CLIs.
     common/install-mise.sh

  6. Restore LazyVim and install the intended Mason inventory.
     common/install-neovim-tools.sh
EOF

  step=7
  if [[ "$install_ocaml" == "true" ]]; then
    cat <<EOF

  $step. Install Fedora OCaml build prerequisites, then create the opam switch.
     platforms/fedora/scripts/install-ocaml.sh
     common/install-ocaml.sh
EOF
    step=$((step + 1))
  fi

  cat <<EOF

  $step. Install the pinned Catppuccin tmux theme.
     common/install-tmux-theme.sh

  $((step + 1)). Verify WSL detection, Linux command ownership and runtime startup.
     platforms/fedora-wsl/scripts/verify.sh$([[ "$run_smoke_tests" == "true" ]] && printf ' --smoke-test')

Excluded: KDE, Sway, Ghostty, ASUS/ROG, NVIDIA, VM host/guest, desktop,
LaTeX and AI tooling.

No changes were made.

EOF
  exit 0
fi

require_fedora_wsl

if systemd_is_running; then
  info "systemd detected as PID 1"
else
  warn "systemd is not PID 1; this profile does not require it"
fi

if [[ "$PWD" == /mnt/[a-zA-Z]/* ]]; then
  warn "Run and keep repositories in the WSL Linux filesystem (for example ~/src), not under /mnt/c"
fi

if [[ "$interactive" == "true" ]]; then
  printf '\nFedora WSL workstation installation\n'
  printf '%s\n' '-----------------------------------'
  printf 'Catppuccin flavour: %s\n' "$theme"
  printf 'OCaml profile:      %s\n' "$install_ocaml"
  printf 'Workflow smoke test: %s\n\n' "$run_smoke_tests"
  confirm "Continue with installation?" "y" || exit 0
fi

"$DOTFILES_ROOT/platforms/fedora-wsl/scripts/install-system.sh"

if [[ "$install_ocaml" == "true" ]]; then
  "$DOTFILES_ROOT/platforms/fedora/scripts/install-ocaml.sh"
fi

"$DOTFILES_ROOT/common/setup-local.sh" "$theme"
"$DOTFILES_ROOT/platforms/fedora-wsl/scripts/stow.sh"
"$DOTFILES_ROOT/common/install-mise.sh"
"$DOTFILES_ROOT/common/install-neovim-tools.sh"

if [[ "$install_ocaml" == "true" ]]; then
  "$DOTFILES_ROOT/common/install-ocaml.sh"
fi

"$DOTFILES_ROOT/common/install-tmux-theme.sh"

theme_command="$HOME/.local/bin/theme"
if [[ -x "$theme_command" ]]; then
  "$theme_command" "$theme"
fi

verify_args=()
if [[ "$run_smoke_tests" == "true" ]]; then
  verify_args+=(--smoke-test)
fi

printf '\n'
info "Verifying Fedora WSL installation"
"$DOTFILES_ROOT/platforms/fedora-wsl/scripts/verify.sh" "${verify_args[@]}"

cat <<'EOF'

Fedora WSL setup completed. Zsh will be used for new sessions. Run `exec zsh -l`
to replace the shell in the current terminal.

Manual choices still remain for Git identity and authentication. See the
Fedora WSL section in README.md; no credentials are stored in this repository.
EOF
