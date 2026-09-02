#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

theme="macchiato"
install_kde="auto"
install_latex="false"
interactive="true"
dry_run="false"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --theme FLAVOUR    Catppuccin flavour:
                     latte, frappe, macchiato, mocha
                     Default: macchiato

  --kde              Install Catppuccin KDE integration
  --no-kde           Do not install KDE integration

  --latex            Install the LaTeX toolchain
  --no-latex         Do not install the LaTeX toolchain

  --dry-run          Show the installation plan without changing anything
  --non-interactive  Use defaults without prompting

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

  --kde)
    install_kde="true"
    shift
    ;;

  --no-kde)
    install_kde="false"
    shift
    ;;

  --latex)
    install_latex="true"
    shift
    ;;

  --no-latex)
    install_latex="false"
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
    die "Unknown option: $1"
    ;;
  esac
done

case "$theme" in
latte | frappe | macchiato | mocha)
  ;;
*)
  die "Invalid Catppuccin flavour: $theme"
  ;;
esac

# ---------------------------------------------------------------------------
# Resolve automatic options
# ---------------------------------------------------------------------------

if [[ "$install_kde" == "auto" ]]; then
  if command_exists plasmashell; then
    install_kde="true"
  else
    install_kde="false"
  fi
fi

# ---------------------------------------------------------------------------
# Dry-run / installation plan
# ---------------------------------------------------------------------------

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Dotfiles installation plan
--------------------------

Catppuccin flavour:  $theme
KDE integration:     $install_kde
LaTeX toolchain:     $install_latex

Steps:

  1. Install Fedora system packages
     scripts/install-system.sh

  2. Enable Terra and install Terra-managed packages
     scripts/install-terra.sh

  3. Deploy tracked configuration with GNU Stow
     scripts/stow.sh

  4. Initialize machine-local configuration
     scripts/setup-local.sh $theme

  5. Install mise-managed runtimes and developer tools
     scripts/install-mise.sh

  6. Install pinned Catppuccin tmux theme
     scripts/install-tmux-theme.sh
EOF

  step=7

  if [[ "$install_kde" == "true" ]]; then
    cat <<EOF

  $step. Install all four Catppuccin KDE themes
     Mauve accent
     Classic window decoration
     Catppuccin cursors
     scripts/install-kde-theme.sh
EOF
    step=$((step + 1))
  fi

  if [[ "$install_latex" == "true" ]]; then
    cat <<EOF

  $step. Install LaTeX toolchain
     scripts/install-latex.sh
EOF
    step=$((step + 1))
  fi

  cat <<EOF

  $step. Apply Catppuccin $theme
     ~/.local/bin/theme $theme

  $((step + 1)). Verify installation
     scripts/verify.sh

Manual configuration still required afterward:

  • Configure ~/.config/git/local with the default Git identity.
  • Configure ~/.config/git/drdk if a separate DR/work identity is required.
  • Configure SSH authentication.
  • Authenticate GitHub CLI with gh auth login.
  • Open Neovim once so lazy.nvim and Mason can finish editor setup.

No changes were made.

EOF

  exit 0
fi

# ---------------------------------------------------------------------------
# Interactive choices
# ---------------------------------------------------------------------------

if [[ "$interactive" == "true" ]]; then
  printf '\n'
  printf 'Dotfiles installation\n'
  printf '%s\n' '---------------------'
  printf 'Catppuccin flavour: %s\n' "$theme"
  printf 'KDE integration:    %s\n' "$install_kde"
  printf '\n'

  if [[ "$install_latex" == "false" ]]; then
    if confirm "Install LaTeX toolchain?" "n"; then
      install_latex="true"
    fi
  fi

  printf '\n'
  printf 'Installation choices\n'
  printf '%s\n' '--------------------'
  printf 'Catppuccin flavour: %s\n' "$theme"
  printf 'KDE integration:    %s\n' "$install_kde"
  printf 'LaTeX toolchain:    %s\n' "$install_latex"
  printf '\n'

  confirm "Continue with installation?" "y" || exit 0
fi

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

info "Installing base Fedora packages"
"$DOTFILES_ROOT/scripts/install-system.sh"

info "Installing Terra packages"
"$DOTFILES_ROOT/scripts/install-terra.sh"

info "Deploying dotfiles with GNU Stow"
"$DOTFILES_ROOT/scripts/stow.sh"

info "Initializing machine-local configuration"
"$DOTFILES_ROOT/scripts/setup-local.sh" "$theme"

info "Installing mise-managed runtimes and tools"
"$DOTFILES_ROOT/scripts/install-mise.sh"

info "Installing Catppuccin tmux"
"$DOTFILES_ROOT/scripts/install-tmux-theme.sh"

if [[ "$install_kde" == "true" ]]; then
  info "Installing Catppuccin KDE themes"
  "$DOTFILES_ROOT/scripts/install-kde-theme.sh"
fi

if [[ "$install_latex" == "true" ]]; then
  info "Installing LaTeX toolchain"
  "$DOTFILES_ROOT/scripts/install-latex.sh"
fi

# ---------------------------------------------------------------------------
# Apply selected flavour
# ---------------------------------------------------------------------------

theme_command="$HOME/.local/bin/theme"

if [[ -x "$theme_command" ]]; then
  "$theme_command" "$theme"
else
  warn "Theme command not available: $theme_command"
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

printf '\n'
info "Verifying installation"

if "$DOTFILES_ROOT/scripts/verify.sh"; then
  printf '\n'
  success "Installation completed successfully"
else
  printf '\n'
  warn "Installation completed, but verification reported problems"
  exit 1
fi

cat <<'EOF'

Manual configuration may still be required:

  • Configure ~/.config/git/local with your default Git identity.
  • Configure ~/.config/git/drdk if you use a separate DR/work identity.
  • Configure SSH authentication (for example 1Password or OpenSSH).
  • Authenticate GitHub CLI with:
      gh auth login
  • Open Neovim once so lazy.nvim and Mason can finish installing editor tooling.

EOF
