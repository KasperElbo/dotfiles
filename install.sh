#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/common.sh"

theme="macchiato"
install_kde="auto"
install_latex="false"
install_sway="false"
hardware_model=""
hardware_secure_boot="false"
hardware_charge_limit=""
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

  --sway             Install the optional keyboard-driven Sway session
  --no-sway          Do not install the Sway session (default)

  --hardware MODEL   Install ASUS hardware support:
                     ga402xz or ga402rk
                     Default: disabled
  --secure-boot      Require Secure Boot for the selected hardware
  --charge-limit N   Set ASUS battery charge limit (40-100 percent)

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

  --sway)
    install_sway="true"
    shift
    ;;

  --no-sway)
    install_sway="false"
    shift
    ;;

  --hardware)
    [[ $# -ge 2 ]] || die "--hardware requires a value"
    hardware_model="$2"
    shift 2
    ;;

  --secure-boot)
    hardware_secure_boot="true"
    shift
    ;;

  --charge-limit)
    [[ $# -ge 2 ]] || die "--charge-limit requires a value"
    hardware_charge_limit="$2"
    shift 2
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

case "$hardware_model" in
"" | ga402xz | ga402rk)
  ;;
*)
  die "Invalid hardware profile: $hardware_model"
  ;;
esac

if [[ "$hardware_secure_boot" == "true" && -z "$hardware_model" ]]; then
  die "--secure-boot requires --hardware"
fi

if [[ -n "$hardware_charge_limit" ]]; then
  [[ -n "$hardware_model" ]] || die "--charge-limit requires --hardware"

  if [[ ! "$hardware_charge_limit" =~ ^[0-9]+$ ]] ||
    ((hardware_charge_limit < 40 || hardware_charge_limit > 100)); then
    die "--charge-limit must be an integer from 40 to 100"
  fi
fi

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
  sway_suffix=""
  if [[ "$install_sway" == "true" ]]; then
    sway_suffix=" --sway"
  fi

  cat <<EOF

Dotfiles installation plan
--------------------------

Catppuccin flavour:  $theme
KDE integration:     $install_kde
LaTeX toolchain:     $install_latex
Sway session:        $install_sway
ASUS hardware:       ${hardware_model:-disabled}
Require Secure Boot: $hardware_secure_boot
Battery limit:       ${hardware_charge_limit:-unchanged}

Steps:

  1. Install Fedora system packages
     scripts/install-system.sh

  2. Enable Terra and install Terra-managed packages
     scripts/install-terra.sh
EOF

  step=3

  if [[ -n "$hardware_model" ]]; then
    cat <<EOF

  $step. Install ASUS hardware support for $hardware_model
     scripts/install-asus-hardware.sh --model $hardware_model
EOF
    step=$((step + 1))
  fi

  if [[ "$install_sway" == "true" ]]; then
    cat <<EOF

  $step. Install the optional Sway daily-driver session
     scripts/install-sway.sh
EOF
    step=$((step + 1))
  fi

  cat <<EOF

  $step. Initialize machine-local configuration
     scripts/setup-local.sh $theme$sway_suffix

  $((step + 1)). Deploy tracked configuration with GNU Stow
     scripts/stow.sh$sway_suffix

  $((step + 2)). Install mise-managed runtimes and developer tools
     scripts/install-mise.sh

  $((step + 3)). Install pinned Catppuccin tmux theme
     scripts/install-tmux-theme.sh
EOF

  step=$((step + 4))

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
  printf 'Sway session:       %s\n' "$install_sway"
  printf 'ASUS hardware:      %s\n' "${hardware_model:-disabled}"
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
  printf 'Sway session:       %s\n' "$install_sway"
  printf 'ASUS hardware:      %s\n' "${hardware_model:-disabled}"

  if [[ -n "$hardware_model" ]]; then
    printf 'Require Secure Boot: %s\n' "$hardware_secure_boot"
    printf 'Battery limit:       %s\n' "${hardware_charge_limit:-unchanged}"
  fi

  printf '\n'

  confirm "Continue with installation?" "y" || exit 0
fi

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

hardware_args=()

if [[ -n "$hardware_model" ]]; then
  hardware_args=(--model "$hardware_model")

  if [[ "$hardware_secure_boot" == "true" ]]; then
    hardware_args+=(--secure-boot)
  fi

  if [[ -n "$hardware_charge_limit" ]]; then
    hardware_args+=(--charge-limit "$hardware_charge_limit")
  fi

  info "Validating ASUS hardware requirements"
  "$DOTFILES_ROOT/scripts/install-asus-hardware.sh" \
    "${hardware_args[@]}" --preflight
fi

info "Installing base Fedora packages"
"$DOTFILES_ROOT/scripts/install-system.sh"

info "Installing Terra packages"
"$DOTFILES_ROOT/scripts/install-terra.sh"

if [[ -n "$hardware_model" ]]; then
  if [[ "$interactive" == "false" ]]; then
    hardware_args+=(--non-interactive)
  fi

  info "Installing ASUS hardware support"
  "$DOTFILES_ROOT/scripts/install-asus-hardware.sh" "${hardware_args[@]}"
fi

if [[ "$install_sway" == "true" ]]; then
  info "Installing optional Sway session"
  "$DOTFILES_ROOT/scripts/install-sway.sh"
fi

info "Initializing machine-local configuration"
setup_local_args=("$theme")
stow_args=()

if [[ "$install_sway" == "true" ]]; then
  setup_local_args+=(--sway)
  stow_args+=(--sway)
fi

"$DOTFILES_ROOT/scripts/setup-local.sh" "${setup_local_args[@]}"

info "Deploying dotfiles with GNU Stow"
"$DOTFILES_ROOT/scripts/stow.sh" "${stow_args[@]}"

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
