#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/common.sh"
# shellcheck source=lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/wsl.sh"

theme="macchiato"
install_ocaml="false"
install_latex="false"
install_containers="false"
containers_api_socket="false"
install_ai="false"
ai_codex="false"
ai_firstmate="false"
ai_gnhf="false"
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

  --latex            Install the optional Fedora-owned LaTeX toolchain
  --no-latex         Do not install the LaTeX toolchain (default)

  --containers       Install the optional rootless Podman container
                     development profile (see README.md, "Optional Podman
                     container development profile"). Requires systemd as
                     PID 1 inside this WSL distribution.
  --no-containers    Do not install the containers profile (default)
  --containers-api-socket
                     With --containers, enable the rootless, socket-activated
                     Podman API socket for Docker-compatible client tooling
                     (default: disabled)

  --ai               Install the optional AI-assisted development profile:
                     Claude Code and Herdr (see README.md, "AI-assisted
                     development toolchain")
  --no-ai            Do not install the AI profile (default)
  --codex            With --ai, also install the OpenAI Codex CLI
  --no-codex         Do not install Codex (default)
  --firstmate        With --ai, also clone the FirstMate multi-agent
                     coordinator
  --no-firstmate     Do not clone FirstMate (default)
  --gnhf             With --ai, also install GNHF, an unattended overnight
                     agent orchestrator (read README.md, "Optional: GNHF"
                     before use; it runs an agent unsupervised)
  --no-gnhf          Do not install GNHF (default)

  --smoke-test       Run representative development workflow tests after setup
  --dry-run          Show the installation plan without changing anything
  --non-interactive  Use defaults without prompting

  -h, --help         Show this help

Desktop, hardware, and VM-host/guest profiles are not part of the Fedora WSL
workstation variant. The AI profile is portable CLI tooling with no GUI or
hardware dependency, so it is fully supported here; see README.md, "Fedora
on WSL".
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
  --latex)
    install_latex="true"
    shift
    ;;
  --no-latex)
    install_latex="false"
    shift
    ;;
  --containers)
    install_containers="true"
    shift
    ;;
  --no-containers)
    install_containers="false"
    shift
    ;;
  --containers-api-socket)
    containers_api_socket="true"
    shift
    ;;
  --ai)
    install_ai="true"
    shift
    ;;
  --no-ai)
    install_ai="false"
    shift
    ;;
  --codex)
    ai_codex="true"
    shift
    ;;
  --no-codex)
    ai_codex="false"
    shift
    ;;
  --firstmate)
    ai_firstmate="true"
    shift
    ;;
  --no-firstmate)
    ai_firstmate="false"
    shift
    ;;
  --gnhf)
    ai_gnhf="true"
    shift
    ;;
  --no-gnhf)
    ai_gnhf="false"
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

if [[ "$containers_api_socket" == "true" && "$install_containers" == "false" ]]; then
  die "--containers-api-socket requires --containers"
fi

if [[ "$ai_codex" == "true" && "$install_ai" == "false" ]]; then
  die "--codex requires --ai"
fi

if [[ "$ai_firstmate" == "true" && "$install_ai" == "false" ]]; then
  die "--firstmate requires --ai"
fi

if [[ "$ai_gnhf" == "true" && "$install_ai" == "false" ]]; then
  die "--gnhf requires --ai"
fi

if [[ "$dry_run" == "true" ]]; then
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

  if [[ "$install_latex" == "true" ]]; then
    cat <<EOF

  $step. Install the optional Fedora-owned LaTeX toolchain.
     platforms/fedora/scripts/install-latex.sh
     latexmk, latexindent, Biber and the medium TeX Live scheme
EOF
    step=$((step + 1))
  fi

  if [[ "$install_containers" == "true" ]]; then
    containers_suffix=""
    if [[ "$containers_api_socket" == "true" ]]; then
      containers_suffix=" --api-socket"
    fi
    cat <<EOF

  $step. Check WSL containers prerequisites (systemd, cgroup v2, user
     namespaces), then install the optional rootless Podman profile.
     platforms/fedora-wsl/scripts/install-containers.sh$containers_suffix
     podman, podman-compose; rootless by default, no Docker Engine/alias
EOF
    step=$((step + 1))
  fi

  cat <<EOF

  $step. Install the pinned Catppuccin tmux theme.
     common/install-tmux-theme.sh
EOF
  step=$((step + 1))

  if [[ "$install_ai" == "true" ]]; then
    ai_suffix=""
    if [[ "$ai_codex" == "true" ]]; then
      ai_suffix+=" --codex"
    fi
    if [[ "$ai_firstmate" == "true" ]]; then
      ai_suffix+=" --firstmate"
    fi
    if [[ "$ai_gnhf" == "true" ]]; then
      ai_suffix+=" --gnhf"
    fi
    cat <<EOF

  $step. Install the optional AI-assisted development profile.
     common/install-ai.sh$ai_suffix
     Claude Code and Herdr via mise; Codex: $ai_codex; FirstMate: $ai_firstmate;
     GNHF: $ai_gnhf
EOF
    step=$((step + 1))
  fi

  verify_suffix=""
  if [[ "$run_smoke_tests" == "true" ]]; then
    verify_suffix+=" --smoke-test"
  fi
  if [[ "$install_latex" == "true" ]]; then
    verify_suffix+=" --latex"
  fi

  cat <<EOF

  $step. Verify WSL detection, Linux command ownership and runtime startup.
     platforms/fedora-wsl/scripts/verify.sh$verify_suffix

Excluded: KDE, Sway, Ghostty, ASUS/ROG, NVIDIA, VM host/guest, and desktop.
The AI profile has no GUI or hardware dependency, so --ai/--codex/--firstmate
are supported here.

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
  printf 'LaTeX toolchain:    %s\n' "$install_latex"
  printf 'Containers profile: %s\n' "$install_containers"
  if [[ "$install_containers" == "true" ]]; then
    printf 'Containers API socket: %s\n' "$containers_api_socket"
  fi
  printf 'AI profile:         %s\n' "$install_ai"
  if [[ "$install_ai" == "true" ]]; then
    printf 'AI Codex subcomponent:     %s\n' "$ai_codex"
    printf 'AI FirstMate subcomponent: %s\n' "$ai_firstmate"
    printf 'AI GNHF subcomponent:      %s\n' "$ai_gnhf"
  fi
  printf 'Workflow smoke test: %s\n\n' "$run_smoke_tests"
  confirm "Continue with installation?" "y" || exit 0
fi

"$DOTFILES_ROOT/platforms/fedora-wsl/scripts/install-system.sh"

if [[ "$install_ocaml" == "true" ]]; then
  "$DOTFILES_ROOT/platforms/fedora/scripts/install-ocaml.sh"
fi

if [[ "$install_latex" == "true" ]]; then
  "$DOTFILES_ROOT/platforms/fedora/scripts/install-latex.sh"
fi

"$DOTFILES_ROOT/common/setup-local.sh" "$theme"
"$DOTFILES_ROOT/platforms/fedora-wsl/scripts/stow.sh"
"$DOTFILES_ROOT/common/install-mise.sh"
"$DOTFILES_ROOT/common/install-neovim-tools.sh"

if [[ "$install_ocaml" == "true" ]]; then
  "$DOTFILES_ROOT/common/install-ocaml.sh"
fi

if [[ "$install_containers" == "true" ]]; then
  containers_args=()
  if [[ "$containers_api_socket" == "true" ]]; then
    containers_args+=(--api-socket)
  fi

  info "Installing optional Podman containers profile"
  "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/install-containers.sh" \
    "${containers_args[@]}"
fi

"$DOTFILES_ROOT/common/install-tmux-theme.sh"

if [[ "$install_ai" == "true" ]]; then
  ai_args=()
  if [[ "$ai_codex" == "true" ]]; then
    ai_args+=(--codex)
  fi
  if [[ "$ai_firstmate" == "true" ]]; then
    ai_args+=(--firstmate)
  fi
  if [[ "$ai_gnhf" == "true" ]]; then
    ai_args+=(--gnhf)
  fi

  info "Installing optional AI-assisted development profile"
  "$DOTFILES_ROOT/common/install-ai.sh" "${ai_args[@]}"
fi

theme_command="$HOME/.local/bin/theme"
if [[ -x "$theme_command" ]]; then
  "$theme_command" "$theme"
fi

verify_args=()
if [[ "$run_smoke_tests" == "true" ]]; then
  verify_args+=(--smoke-test)
fi
if [[ "$install_latex" == "true" ]]; then
  verify_args+=(--latex)
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
