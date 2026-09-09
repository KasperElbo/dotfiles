#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

install_codex="false"
install_firstmate="false"
install_gnhf="false"
install_backpass="false"
dry_run="false"
validate_only="false"

# Overridable so tests can point FirstMate's clone, and Treehouse's/No
# Mistakes' install scripts, at local fixtures instead of the real network.
firstmate_repo="${FIRSTMATE_REPO_URL:-https://github.com/kunchenguid/firstmate.git}"
firstmate_dir="$XDG_DATA_HOME/firstmate"
treehouse_install_script="${TREEHOUSE_INSTALL_SCRIPT_URL:-https://kunchenguid.github.io/treehouse/install.sh}"
treehouse_target="$HOME/.local/bin/treehouse"
no_mistakes_install_script="${NO_MISTAKES_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh}"
no_mistakes_target="$HOME/.local/bin/no-mistakes"
agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_md_target="$HOME/.claude/CLAUDE.md"
codex_agents_target="$codex_home/AGENTS.md"
opencode_agents_target="$XDG_CONFIG_HOME/opencode/AGENTS.md"
conf_dir="$XDG_CONFIG_HOME/mise/conf.d"
conf_file="$conf_dir/ai.toml"
state_file="$XDG_CONFIG_HOME/dotfiles/ai.conf"

usage() {
  cat <<'EOF'
Usage: ./common/install-ai.sh [options]

Install the optional AI-assisted development toolchain: Claude Code (the
preferred/core coding agent) and Herdr (the persistent multi-agent terminal
workspace) unconditionally, plus optional subcomponents.

Also unconditionally links a single shared agent-instructions file
(common/assets/AGENTS.md, mirrored from KasperElbo/dotfiles-nix's
home/AGENTS.md) to Claude Code's, Codex's, and OpenCode's global instructions
paths, so one edit updates every harness. See "Shared agent instructions"
in README.md.

Options:
  --codex            Also install the OpenAI Codex CLI
  --firstmate        Also install FirstMate and every tool its own docs
                     list as required: Treehouse, No Mistakes, gh-axi,
                     chrome-devtools-axi, lavish-axi, tasks-axi, and
                     quota-axi (requires 'gh', 'tmux', and 'jq'; see
                     README.md, "AI-assisted development toolchain")
  --gnhf             Also install GNHF, an unattended overnight agent
                     orchestrator (see README.md, "Optional: GNHF" -- read
                     this before use; it runs an agent unsupervised)
  --backpass         Also install backpass, which proposes evidence-backed
                     edits to AGENTS.md/CLAUDE.md from agent session
                     transcripts, gated behind mandatory human review
                     (independent of --firstmate; see README.md,
                     "Optional: backpass")
  --dry-run          Show the AI installation plan without changing anything
  --validate         Validate an existing AI profile installation only
  -h, --help         Show this help

Ownership: Claude Code, Codex, Herdr, GNHF, (with --firstmate) gh-axi,
chrome-devtools-axi, lavish-axi, tasks-axi, and quota-axi, and (with
--backpass) backpass and acpx are installed and updated through mise
(npm/registry backends), in an untracked, machine-local mise config file
(~/.config/mise/conf.d/ai.toml) so the default, always-installed mise
config in this repository never gains an AI dependency. lavish-axi is
declared once even if both --firstmate and --backpass select it. FirstMate,
Treehouse, and No Mistakes have no package manager upstream: FirstMate is
cloned to ~/.local/share/firstmate and updated with 'git pull --ff-only';
Treehouse and No Mistakes are installed to ~/.local/bin via their own
official install scripts and updated by rerunning --firstmate. This
installer never runs 'gh-axi setup hooks' or 'lavish-axi setup hooks'
(optional agent session-start hooks), 'no-mistakes init' (per-repository),
or 'backpass init'/'backpass apply' (per-repository, and the latter is the
only command that writes anything) on your behalf -- see README.md for
those manual, deliberate steps. Authenticate each tool interactively (see
README.md); this installer never stores or requests credentials, and never
passes GNHF's own --push flag on your behalf.
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
  --gnhf)
    install_gnhf="true"
    shift
    ;;
  --backpass)
    install_backpass="true"
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
GNHF (overnight run): $install_gnhf
backpass:             $install_backpass

Steps:
  1. Write $conf_file
     (untracked, machine-local; not part of the always-installed mise config)
     Declares: npm:@anthropic-ai/claude-code, herdr$([[ "$install_codex" == "true" ]] && printf ', npm:@openai/codex')$([[ "$install_gnhf" == "true" ]] && printf ', npm:gnhf')$([[ "$install_firstmate" == "true" ]] && printf ',\n     npm:gh-axi, npm:chrome-devtools-axi, npm:tasks-axi, npm:quota-axi')$([[ "$install_firstmate" == "true" || "$install_backpass" == "true" ]] && printf ', npm:lavish-axi')$([[ "$install_backpass" == "true" ]] && printf ',\n     npm:backpass, npm:acpx')
EOF

  cat <<EOF
  2. mise install
EOF

  cat <<EOF

  3. Link the shared agent-instructions file (common/assets/AGENTS.md,
     mirrored from KasperElbo/dotfiles-nix's home/AGENTS.md) into every
     harness's global instructions path:
     $claude_md_target
     $codex_agents_target
     $opencode_agents_target
     An existing file or symlink pointing elsewhere at any of these paths
     is left untouched, never overwritten.
EOF

  step=4
  if [[ "$install_firstmate" == "true" ]]; then
    cat <<EOF

  $step. Clone or update FirstMate
     $firstmate_repo -> $firstmate_dir
     Requires 'gh', 'tmux', and 'jq' (Herdr is available as an alternative
     crew backend once installed above). Does not register any project or
     authenticate GitHub; see README.md for the manual next steps.

  $((step + 1)). Install Treehouse (worktree isolation for FirstMate crewmates)
     $treehouse_install_script -> $treehouse_target
     Not mise-managed (no registry entry); rerun --firstmate to update it.

  $((step + 2)). Install No Mistakes (local validation gate before a push)
     $no_mistakes_install_script -> $no_mistakes_target
     Not mise-managed (no registry entry); rerun --firstmate to update it.
     Does not run 'no-mistakes init' in any repository for you.
EOF
    step=$((step + 3))
  fi

  if [[ "$install_backpass" == "true" ]]; then
    cat <<EOF

  $step. backpass and acpx are now on PATH
     backpass proposes AGENTS.md/CLAUDE.md edits from session transcripts;
     'backpass apply' is the only command that writes, and only after you
     ACCEPT each edit in its review UI. Does not run 'backpass init' or
     'backpass apply' in any repository for you; see README.md, "Optional:
     backpass" for the manual next steps and its model-routing defaults.
EOF
    step=$((step + 1))
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

if [[ "$install_firstmate" == "true" ]]; then
  require_command gh
  require_command tmux
  require_command jq
  require_command curl
fi

info "Writing $conf_file"
ensure_dir "$conf_dir"
{
  printf '# Managed by dotfiles common/install-ai.sh (optional AI profile).\n'
  printf '# Safe to delete; rerun the AI profile installer to recreate it.\n'
  printf '# Not tracked by the dotfiles repository.\n'
  printf '\n'
  printf '[tools]\n'
  # Claude Code's npm package uses postinstall to link its platform-native
  # binary. mise otherwise disables npm lifecycle scripts by default.
  printf '"npm:@anthropic-ai/claude-code" = { version = "latest", npm_args = "--ignore-scripts=false" }\n'
  printf 'herdr = "latest"\n'
  if [[ "$install_codex" == "true" ]]; then
    printf '"npm:@openai/codex" = "latest"\n'
  fi
  if [[ "$install_gnhf" == "true" ]]; then
    printf '"npm:gnhf" = "latest"\n'
  fi
  if [[ "$install_firstmate" == "true" ]]; then
    printf '"npm:gh-axi" = "latest"\n'
    printf '"npm:chrome-devtools-axi" = "latest"\n'
    printf '"npm:tasks-axi" = "latest"\n'
    printf '"npm:quota-axi" = "latest"\n'
  fi
  # lavish-axi serves FirstMate's rich-review surfaces and backpass's review
  # UI; declared once even if both select it, to avoid a duplicate TOML key.
  if [[ "$install_firstmate" == "true" || "$install_backpass" == "true" ]]; then
    printf '"npm:lavish-axi" = "latest"\n'
  fi
  if [[ "$install_backpass" == "true" ]]; then
    printf '"npm:backpass" = "latest"\n'
    printf '"npm:acpx" = "latest"\n'
  fi
} | atomic_write_file "$conf_file"

mise_tools_msg="Claude Code and Herdr"
if [[ "$install_codex" == "true" ]]; then
  mise_tools_msg+=", Codex"
fi
if [[ "$install_gnhf" == "true" ]]; then
  mise_tools_msg+=", GNHF"
fi
if [[ "$install_firstmate" == "true" ]]; then
  mise_tools_msg+=", gh-axi, chrome-devtools-axi, tasks-axi, and quota-axi"
fi
if [[ "$install_firstmate" == "true" || "$install_backpass" == "true" ]]; then
  mise_tools_msg+=", lavish-axi"
fi
if [[ "$install_backpass" == "true" ]]; then
  mise_tools_msg+=", backpass, and acpx"
fi
info "Installing $mise_tools_msg via mise"
"$mise_command" --yes install

# link_agent_instructions <target>: points a harness's global instructions
# path at this repository's tracked common/assets/AGENTS.md, so editing one
# file updates Claude Code, Codex, and OpenCode together. Never overwrites an
# existing file or a symlink already pointing elsewhere -- an explicit,
# harness-specific instructions file a user put there themselves always wins.
link_agent_instructions() {
  local target="$1"

  ensure_dir "$(dirname "$target")"

  if [[ -L "$target" ]]; then
    if [[ "$(resolve_symlink_target "$target" 2>/dev/null || true)" == "$agents_source" ]]; then
      info "Already linked: $target -> $agents_source"
    else
      warn "Keeping existing symlink (points elsewhere), not linking: $target"
    fi
    return
  fi

  if [[ -e "$target" ]]; then
    warn "Keeping existing file, not linking: $target"
    return
  fi

  ln -s "$agents_source" "$target"
  info "Linked $target -> $agents_source"
}

info "Linking shared agent instructions (common/assets/AGENTS.md)"
link_agent_instructions "$claude_md_target"
link_agent_instructions "$codex_agents_target"
link_agent_instructions "$opencode_agents_target"

# install_via_own_script <name> <script_url> <target>: installs a tool with
# no mise registry entry and no OS package via its official curl|sh script.
# Every such script this profile uses picks the first of ~/.local/bin or
# /usr/local/bin that is on PATH, silently escalating to sudo for the
# latter -- so this ensures ~/.local/bin exists and is searched first,
# guaranteeing a user-owned install with no unexpected privilege escalation.
install_via_own_script() {
  local name="$1" script_url="$2" target="$3"

  info "Installing $name: $target"
  ensure_dir "$(dirname "$target")"
  PATH="$(dirname "$target"):$PATH" \
    sh -c "curl --fail --show-error --silent --location '$script_url' | sh"
}

firstmate_state="disabled"
treehouse_state="disabled"
no_mistakes_state="disabled"
if [[ "$install_firstmate" == "true" ]]; then
  if [[ -d "$firstmate_dir/.git" ]]; then
    info "Updating FirstMate: $firstmate_dir"
    git -C "$firstmate_dir" pull --ff-only
  else
    info "Cloning FirstMate: $firstmate_repo"
    ensure_dir "$(dirname "$firstmate_dir")"
    git clone "$firstmate_repo" "$firstmate_dir"
  fi
  firstmate_state="cloned"

  install_via_own_script Treehouse "$treehouse_install_script" "$treehouse_target"
  treehouse_state="installed"

  install_via_own_script "No Mistakes" "$no_mistakes_install_script" "$no_mistakes_target"
  no_mistakes_state="installed"
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
  printf 'no_mistakes=%s\n' "$no_mistakes_state"
  if [[ "$install_firstmate" == "true" ]]; then
    printf 'gh_axi=mise-npm\n'
    printf 'chrome_devtools_axi=mise-npm\n'
    printf 'tasks_axi=mise-npm\n'
    printf 'quota_axi=mise-npm\n'
  else
    printf 'gh_axi=disabled\n'
    printf 'chrome_devtools_axi=disabled\n'
    printf 'tasks_axi=disabled\n'
    printf 'quota_axi=disabled\n'
  fi
  if [[ "$install_firstmate" == "true" || "$install_backpass" == "true" ]]; then
    printf 'lavish_axi=mise-npm\n'
  else
    printf 'lavish_axi=disabled\n'
  fi
  if [[ "$install_gnhf" == "true" ]]; then
    printf 'gnhf=mise-npm\n'
  else
    printf 'gnhf=disabled\n'
  fi
  if [[ "$install_backpass" == "true" ]]; then
    printf 'backpass=mise-npm\n'
    printf 'acpx=mise-npm\n'
  else
    printf 'backpass=disabled\n'
    printf 'acpx=disabled\n'
  fi
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

cat <<EOF
  • Shared agent instructions: edit common/assets/AGENTS.md in this
    repository to change what Claude Code, Codex, and OpenCode all see;
    it is linked to $claude_md_target, $codex_agents_target, and
    $opencode_agents_target (any of these left untouched above already
    had its own file or symlink, which takes precedence).
EOF

if [[ "$install_firstmate" == "true" ]]; then
  cat <<EOF
  • FirstMate is cloned but not configured: read $firstmate_dir/README.md,
    run 'gh auth login' if you have not, then register a project and launch
    a coordinator session as documented there.
  • Treehouse, tasks-axi, and quota-axi need no separate configuration;
    FirstMate uses them automatically.
  • No Mistakes ($no_mistakes_target) gates pushes per-repository, not
    automatically: run 'no-mistakes init' inside a repository to set it up,
    then push to it with 'git push no-mistakes <branch>' instead of your
    normal remote. Until you do that, it changes nothing about how you push.
  • gh-axi and lavish-axi can optionally add a Claude Code/Codex/OpenCode
    SessionStart hook for ambient context ('gh-axi setup hooks',
    'lavish-axi setup hooks'). This installer does not run either for you.
EOF
fi

if [[ "$install_gnhf" == "true" ]]; then
  cat <<'EOF'
  • GNHF runs an agent (default: Claude Code) unattended, with no
    per-iteration human checkpoint. Read its README before your first run:
    https://github.com/kunchenguid/gnhf. By default it commits to a local
    'gnhf/<slug>' branch and never pushes; it only pushes if you pass its
    own --push flag yourself. This installer never adds --push for you.
EOF
fi

if [[ "$install_backpass" == "true" ]]; then
  cat <<'EOF'
  • backpass needs no separate configuration to install, but does nothing
    until you run it: 'backpass init' (per-repository) sets it up, then
    'backpass' analyzes and proposes edits (never writes), and
    'backpass apply' opens a review UI where you ACCEPT/REJECT each edit
    individually -- it is the only command that writes anything. Its
    default model routing may call a non-Claude model for analysis/
    synthesis; pass '--analysis-agent'/'--synthesis-agent' to pin one
    provider if you want that. Read its README before your first run:
    https://github.com/kunchenguid/backpass.
EOF
fi
