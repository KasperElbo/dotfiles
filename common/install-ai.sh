#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

install_codex="false"
install_firstmate="false"
dry_run="false"
validate_only="false"

# Overridable so tests can point FirstMate's clone, and Treehouse's install
# script, at local fixtures instead of the real network.
firstmate_repo="${FIRSTMATE_REPO_URL:-https://github.com/kunchenguid/firstmate.git}"
firstmate_dir="$XDG_DATA_HOME/firstmate"
treehouse_install_script="${TREEHOUSE_INSTALL_SCRIPT_URL:-https://kunchenguid.github.io/treehouse/install.sh}"
treehouse_target="$HOME/.local/bin/treehouse"
conf_dir="$XDG_CONFIG_HOME/mise/conf.d"
conf_file="$conf_dir/ai.toml"
state_file="$XDG_CONFIG_HOME/dotfiles/ai.conf"

usage() {
  cat <<'EOF'
Usage: ./common/install-ai.sh [options]

Install the optional AI-assisted development toolchain: Claude Code (the
preferred/core coding agent) and Herdr (the persistent multi-agent terminal
workspace) unconditionally, plus optional subcomponents.

Options:
  --codex            Also install the OpenAI Codex CLI
  --firstmate        Also clone the FirstMate multi-agent coordinator and
                     install Treehouse, its worktree-isolation tool
                     (requires 'gh' and 'tmux'; see README.md, "AI-assisted
                     development toolchain")
  --dry-run          Show the AI installation plan without changing anything
  --validate         Validate an existing AI profile installation only
  -h, --help         Show this help

Ownership: Claude Code, Codex, and Herdr are installed and updated through
mise (npm/registry backends), in an untracked, machine-local mise config
file (~/.config/mise/conf.d/ai.toml) so the default, always-installed mise
config in this repository never gains an AI dependency. FirstMate and
Treehouse have no package manager upstream: FirstMate is cloned to
~/.local/share/firstmate and updated with 'git pull --ff-only'; Treehouse is
installed to ~/.local/bin/treehouse via its own official install script and
updated by rerunning --firstmate. Authenticate each tool interactively (see
README.md); this installer never stores or requests credentials.
EOF
}

while (($#)); do
  case "$1" in
  --codex)
    install_codex="true"
    shift
    ;;
  --firstmate)
    install_firstmate="true"
    shift
    ;;
  --dry-run)
    dry_run="true"
    shift
    ;;
  --validate)
    validate_only="true"
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

if [[ "$dry_run" == "true" && "$validate_only" == "true" ]]; then
  die "--dry-run and --validate cannot be combined"
fi

if [[ "$validate_only" == "true" ]]; then
  exec "$DOTFILES_ROOT/common/verify-ai.sh"
fi

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

AI-assisted development toolchain installation plan
----------------------------------------------------

Claude Code:          installed via mise (npm backend); preferred/core agent
Herdr:                installed via mise; persistent multi-agent terminal
                      workspace used to run Claude Code (and Codex) panes
Codex CLI:            $install_codex
FirstMate crew stack: $install_firstmate

Steps:
  1. Write $conf_file
     (untracked, machine-local; not part of the always-installed mise config)
EOF

  if [[ "$install_codex" == "true" ]]; then
    cat <<EOF
     Declares: npm:@anthropic-ai/claude-code, herdr, npm:@openai/codex
EOF
  else
    cat <<EOF
     Declares: npm:@anthropic-ai/claude-code, herdr
EOF
  fi

  cat <<EOF
  2. mise install
EOF

  step=3
  if [[ "$install_firstmate" == "true" ]]; then
    cat <<EOF

  $step. Clone or update FirstMate
     $firstmate_repo -> $firstmate_dir
     Requires 'gh' and 'tmux' (Herdr is available as an alternative crew
     backend once installed above). Does not register any project or
     authenticate GitHub; see README.md for the manual next steps.

  $((step + 1)). Install Treehouse (worktree isolation for FirstMate crewmates)
     $treehouse_install_script -> $treehouse_target
     Not mise-managed (no registry entry); rerun --firstmate to update it.
EOF
    step=$((step + 2))
  fi

  cat <<EOF

  $step. Record the profile in $state_file
  $((step + 1)). Validate the AI profile

Does not authenticate any agent, does not push/merge/force-push/delete Git
branches or PRs, and does not modify project or global Git configuration.

No changes were made.

EOF
  exit 0
fi

require_command git

mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi
[[ -n "$mise_command" ]] || die "Required command not found: mise"

info "Writing $conf_file"
ensure_dir "$conf_dir"
{
  printf '# Managed by dotfiles common/install-ai.sh (optional AI profile).\n'
  printf '# Safe to delete; rerun the AI profile installer to recreate it.\n'
  printf '# Not tracked by the dotfiles repository.\n'
  printf '\n'
  printf '[tools]\n'
  printf '"npm:@anthropic-ai/claude-code" = "latest"\n'
  printf 'herdr = "latest"\n'
  if [[ "$install_codex" == "true" ]]; then
    printf '"npm:@openai/codex" = "latest"\n'
  fi
} | atomic_write_file "$conf_file"

if [[ "$install_codex" == "true" ]]; then
  info "Installing Claude Code, Herdr, and Codex via mise"
else
  info "Installing Claude Code and Herdr via mise"
fi
"$mise_command" --yes install

firstmate_state="disabled"
treehouse_state="disabled"
if [[ "$install_firstmate" == "true" ]]; then
  require_command gh
  require_command tmux
  require_command curl

  if [[ -d "$firstmate_dir/.git" ]]; then
    info "Updating FirstMate: $firstmate_dir"
    git -C "$firstmate_dir" pull --ff-only
  else
    info "Cloning FirstMate: $firstmate_repo"
    ensure_dir "$(dirname "$firstmate_dir")"
    git clone "$firstmate_repo" "$firstmate_dir"
  fi
  firstmate_state="cloned"

  # Treehouse has no mise registry entry and no OS package; its own install
  # script is the only supported mechanism. It has no destination override,
  # placing the binary in the first of ~/.local/bin or /usr/local/bin that is
  # on PATH, escalating to sudo for the latter -- so ensure ~/.local/bin
  # exists and is searched first here, guaranteeing a user-owned install with
  # no unexpected privilege escalation.
  info "Installing Treehouse: $treehouse_target"
  ensure_dir "$(dirname "$treehouse_target")"
  PATH="$(dirname "$treehouse_target"):$PATH" \
    sh -c "curl --fail --show-error --silent --location '$treehouse_install_script' | sh"
  treehouse_state="installed"
fi

info "Recording the AI profile in $state_file"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=ai\n'
  printf 'claude_code=mise-npm\n'
  printf 'herdr=mise\n'
  if [[ "$install_codex" == "true" ]]; then
    printf 'codex=mise-npm\n'
  else
    printf 'codex=disabled\n'
  fi
  printf 'firstmate=%s\n' "$firstmate_state"
  printf 'treehouse=%s\n' "$treehouse_state"
} | atomic_write_file "$state_file"

info "Validating the AI profile"
if "$DOTFILES_ROOT/common/verify-ai.sh"; then
  success "AI profile installed"
else
  warn "AI tooling installed, but validation reported problems"
  exit 1
fi

cat <<'EOF'

Manual steps still required:

  • Authenticate Claude Code: run 'claude' and follow the browser login
    prompt (or set ANTHROPIC_API_KEY for API-key auth).
EOF

if [[ "$install_codex" == "true" ]]; then
  cat <<'EOF'
  • Authenticate Codex: run 'codex' and choose "Sign in with ChatGPT" (or
    configure an OpenAI API key).
EOF
fi

cat <<'EOF'
  • Start or reattach a Herdr workspace: run 'herdr' in a project directory;
    detach and 'herdr' again to reattach. See https://herdr.dev/docs.
EOF

if [[ "$install_firstmate" == "true" ]]; then
  cat <<EOF
  • FirstMate is cloned but not configured: read $firstmate_dir/README.md,
    run 'gh auth login' if you have not, then register a project and launch
    a coordinator session as documented there.
  • Treehouse ($treehouse_target) needs no separate configuration; FirstMate
    uses it automatically. Run 'treehouse --help' to use it directly.
EOF
fi
