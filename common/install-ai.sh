#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fetch.sh"
# shellcheck source=lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/profile-state.sh"

# Optional subcomponents follow additive semantics: an omitted sub-flag means
# "leave whatever is installed alone", never "reconcile to absent". Removal is
# always an explicit --no-<component>, is previewed by --dry-run, is confirmed
# before it runs, and only ever deletes a path whose recorded provenance proves
# this repository owns it. See docs/supply-chain.md, "AI component transitions".
AI_OPTIONAL_COMPONENTS=(codex firstmate gnhf backpass)

# Staged remote installer content is never left behind, including when the
# installer is interrupted rather than failing on its own terms.
AI_STAGING_DIRS=()
ai_remove_staging() {
  local directory
  for directory in ${AI_STAGING_DIRS[@]+"${AI_STAGING_DIRS[@]}"}; do
    [[ -z "$directory" ]] || rm -rf -- "$directory"
  done
  AI_STAGING_DIRS=()
}
trap ai_remove_staging EXIT INT TERM

declare -A requested_flag=()
dry_run="false"
validate_only="false"
interactive="true"

# Overridable so tests can point FirstMate's clone, and Treehouse's/No
# Mistakes' install scripts, at local fixtures instead of the real network.
firstmate_repo="${FIRSTMATE_REPO_URL:-https://github.com/kunchenguid/firstmate.git}"
firstmate_dir="$XDG_DATA_HOME/firstmate"
treehouse_install_script="${TREEHOUSE_INSTALL_SCRIPT_URL:-https://kunchenguid.github.io/treehouse/install.sh}"
treehouse_target="$HOME/.local/bin/treehouse"
no_mistakes_install_script="${NO_MISTAKES_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh}"
no_mistakes_target="$HOME/.local/bin/no-mistakes"

# Optional recorded digests. Neither upstream publishes a checksum for its
# install script, so these are normally empty and the source stays in the
# reviewed-live tier. Setting one turns that source into a hard integrity
# check; it is never derived from the live URL at install time, because a
# self-computed hash of mutable content proves nothing.
treehouse_expected_sha256="${TREEHOUSE_INSTALL_SCRIPT_SHA256:-}"
no_mistakes_expected_sha256="${NO_MISTAKES_INSTALL_SCRIPT_SHA256:-}"

agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_md_target="$HOME/.claude/CLAUDE.md"
codex_agents_target="$codex_home/AGENTS.md"
opencode_agents_target="$XDG_CONFIG_HOME/opencode/AGENTS.md"
conf_dir="$XDG_CONFIG_HOME/mise/conf.d"
conf_file="$conf_dir/ai.toml"
conf_marker='# Managed by dotfiles common/install-ai.sh (optional AI profile).'
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
  --no-codex, --no-firstmate, --no-gnhf, --no-backpass
                     Remove that subcomponent. This is the only way to
                     uninstall one; see "Transitions" below.
  --non-interactive  Do not prompt. Required as the explicit acknowledgement
                     when a --no-<component> removal runs unattended.
  --dry-run          Show the AI installation plan without changing anything
  --validate         Validate an existing AI profile installation only
  -h, --help         Show this help

Transitions: subcomponent selection is additive. Omitting a sub-flag leaves an
already-installed subcomponent exactly as it is; it never reconciles it away.
Removal happens only for an explicit --no-<component>, is shown by --dry-run,
and is confirmed first (or acknowledged with --non-interactive). A removal only
deletes paths whose recorded provenance still proves this repository installed
them: a binary a user replaced, or a FirstMate checkout pointed at a different
remote, is reported for manual action instead of being deleted.

Ownership: Claude Code, Codex, Herdr, GNHF, (with --firstmate) gh-axi,
chrome-devtools-axi, lavish-axi, tasks-axi, and quota-axi, and (with
--backpass) backpass and acpx are installed and updated through mise
(npm/registry backends), in an untracked, machine-local mise config file
(~/.config/mise/conf.d/ai.toml) so the default, always-installed mise
config in this repository never gains an AI dependency. lavish-axi is
declared once even if both --firstmate and --backpass select it. Every mise
call runs in the deterministic context described in docs/supply-chain.md, so
the directory you start the installer from cannot change what gets installed.
FirstMate, Treehouse, and No Mistakes have no package manager upstream:
FirstMate is cloned to ~/.local/share/firstmate on a deliberately rolling
channel with the resolved commit recorded in the profile state, and updated
with 'git pull --ff-only'; Treehouse and No Mistakes are staged to a private
temporary file, validated, executed, and verified, with the digest of the
script that actually ran recorded, and are updated by rerunning --firstmate.
This installer never runs 'gh-axi setup hooks' or 'lavish-axi setup hooks'
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
  --codex | --firstmate | --gnhf | --backpass)
    requested_flag["${1#--}"]="true"
    shift
    ;;
  --no-codex | --no-firstmate | --no-gnhf | --no-backpass)
    requested_flag["${1#--no-}"]="false"
    shift
    ;;
  --non-interactive)
    interactive="false"
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

# --- Observed state ---------------------------------------------------------

state_value() {
  local key="$1"

  [[ -f "$state_file" ]] || return 1
  profile_state_read "$state_file" "$key" ai 2>/dev/null
}

observed_value() {
  state_value "$1" || printf 'disabled\n'
}

component_is_installed() {
  case "$1" in
  codex) [[ "$(observed_value codex)" == mise-npm ]] ;;
  firstmate) [[ "$(observed_value firstmate)" == cloned ]] ;;
  gnhf) [[ "$(observed_value gnhf)" == mise-npm ]] ;;
  backpass) [[ "$(observed_value backpass)" == mise-npm ]] ;;
  *) return 1 ;;
  esac
}

# Additive resolution: an explicit flag wins; otherwise keep what is installed.
declare -A desired=() transition=()
for component in "${AI_OPTIONAL_COMPONENTS[@]}"; do
  if [[ -n "${requested_flag[$component]:-}" ]]; then
    desired["$component"]="${requested_flag[$component]}"
  elif component_is_installed "$component"; then
    desired["$component"]="true"
  else
    desired["$component"]="false"
  fi

  if [[ "${desired[$component]}" == "true" ]]; then
    if component_is_installed "$component"; then
      transition["$component"]="keep"
    else
      transition["$component"]="install"
    fi
  elif component_is_installed "$component"; then
    transition["$component"]="remove"
  else
    transition["$component"]="absent"
  fi
done

install_codex="${desired[codex]}"
install_firstmate="${desired[firstmate]}"
install_gnhf="${desired[gnhf]}"
install_backpass="${desired[backpass]}"
install_lavish_axi="false"
if [[ "$install_firstmate" == "true" || "$install_backpass" == "true" ]]; then
  install_lavish_axi="true"
fi

requested_summary=""
for component in "${AI_OPTIONAL_COMPONENTS[@]}"; do
  [[ "${desired[$component]}" == "true" ]] || continue
  requested_summary+="${requested_summary:+,}$component"
done
requested_summary="${requested_summary:-none}"

# A destructive step only ever happens because the caller asked for one.
removal_requested="false"
for component in "${AI_OPTIONAL_COMPONENTS[@]}"; do
  [[ "${requested_flag[$component]:-}" != "false" ]] || removal_requested="true"
done

# --- Provenance-proved ownership -------------------------------------------
#
# Removal deletes nothing it cannot prove it installed. Each check answers a
# single question: is this exact artifact still the one recorded in the profile
# state? A user-replaced binary, a checkout repointed at another remote, or a
# component installed before provenance was recorded all fail the check, and
# the installer reports manual action instead of deleting anything.

owned_reason=""

own_check_script_binary() {
  local name="$1" target="$2" digest_key="$3"
  local recorded actual

  owned_reason=""
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    owned_reason="already absent"
    return 1
  fi
  if [[ -L "$target" || ! -f "$target" ]]; then
    owned_reason="$target is not a regular file"
    return 1
  fi

  recorded="$(state_value "$digest_key" || true)"
  if [[ -z "$recorded" || "$recorded" == not-recorded ]]; then
    owned_reason="no digest was recorded for $name when it was installed"
    return 1
  fi

  actual="$(fetch_sha256 "$target" 2>/dev/null || true)"
  if [[ "$actual" != "$recorded" ]]; then
    owned_reason="$target no longer matches the recorded digest (expected $recorded, found ${actual:-unreadable})"
    return 1
  fi
  return 0
}

own_check_firstmate() {
  local recorded_source recorded_commit origin head

  owned_reason=""
  if [[ ! -e "$firstmate_dir" ]]; then
    owned_reason="already absent"
    return 1
  fi
  if [[ ! -d "$firstmate_dir/.git" ]]; then
    owned_reason="$firstmate_dir is not a Git checkout"
    return 1
  fi

  recorded_source="$(state_value firstmate_source || true)"
  recorded_commit="$(state_value firstmate_commit || true)"
  if [[ -z "$recorded_source" || -z "$recorded_commit" ]]; then
    owned_reason="no source/commit was recorded for FirstMate when it was cloned"
    return 1
  fi

  origin="$(git -C "$firstmate_dir" config --get remote.origin.url 2>/dev/null || true)"
  if [[ "$origin" != "$recorded_source" ]]; then
    owned_reason="$firstmate_dir points at ${origin:-no remote}, not the recorded $recorded_source"
    return 1
  fi

  if [[ -n "$(git -C "$firstmate_dir" status --porcelain 2>/dev/null || printf 'unreadable')" ]]; then
    owned_reason="$firstmate_dir has local modifications"
    return 1
  fi

  head="$(git -C "$firstmate_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$head" != "$recorded_commit" ]]; then
    owned_reason="$firstmate_dir is at ${head:-an unreadable commit}, not the recorded $recorded_commit"
    return 1
  fi
  return 0
}

# removal_blockers: every reason a requested removal cannot be proved safe.
# Collected before anything is changed so --dry-run reports the same verdict an
# apply run would reach, and so an apply run refuses before it mutates.
removal_blockers=()
removal_paths=()
if [[ "${transition[firstmate]}" == "remove" ]]; then
  if own_check_firstmate; then
    removal_paths+=("tree|$firstmate_dir|FirstMate checkout")
  else
    [[ "$owned_reason" == "already absent" ]] ||
      removal_blockers+=("FirstMate: $owned_reason")
  fi
  for entry in "treehouse:$treehouse_target:treehouse_target_digest" \
    "no-mistakes:$no_mistakes_target:no_mistakes_target_digest"; do
    IFS=: read -r own_name own_target own_key <<<"$entry"
    if own_check_script_binary "$own_name" "$own_target" "$own_key"; then
      removal_paths+=("file|$own_target|$own_name")
    else
      [[ "$owned_reason" == "already absent" ]] ||
        removal_blockers+=("$own_name: $owned_reason")
    fi
  done
fi

# --- mise declaration ownership --------------------------------------------

mise_specs_for_selection() {
  printf '%s\n' '"npm:@anthropic-ai/claude-code"' herdr
  [[ "$install_codex" != "true" ]] || printf '%s\n' '"npm:@openai/codex"'
  [[ "$install_gnhf" != "true" ]] || printf '%s\n' '"npm:gnhf"'
  if [[ "$install_firstmate" == "true" ]]; then
    printf '%s\n' '"npm:gh-axi"' '"npm:chrome-devtools-axi"' \
      '"npm:tasks-axi"' '"npm:quota-axi"'
  fi
  [[ "$install_lavish_axi" != "true" ]] || printf '%s\n' '"npm:lavish-axi"'
  if [[ "$install_backpass" == "true" ]]; then
    printf '%s\n' '"npm:backpass"' '"npm:acpx"'
  fi
}

# Declarations this repository previously wrote. The managed-header check is
# what makes them ownable: an ai.toml a user wrote themselves is never a source
# of uninstall instructions.
mise_specs_previously_declared() {
  [[ -f "$conf_file" ]] || return 0
  grep -Fq "$conf_marker" "$conf_file" || return 0
  sed -n 's/^\("\{0,1\}[^"= ]*"\{0,1\}\)[[:space:]]*=.*/\1/p' "$conf_file"
}

mise_specs_to_uninstall() {
  local previous current
  previous="$(mise_specs_previously_declared | sort -u)"
  current="$(mise_specs_for_selection | sort -u)"
  comm -23 <(printf '%s\n' "$previous") <(printf '%s\n' "$current") |
    sed 's/^"//; s/"$//' | sed '/^$/d'
}

stale_mise_specs=()
if [[ "$removal_requested" == "true" ]]; then
  # Without an explicit --no-<component>, a declaration that is no longer
  # selected means the profile state was lost, not that the tool is unwanted.
  # Additive semantics leaves it installed and lets the verifier report it.
  mapfile -t stale_mise_specs < <(mise_specs_to_uninstall)
fi

# --- Dry run ----------------------------------------------------------------

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

Subcomponent transitions (additive; omitted flags preserve what is installed)
EOF
  for component in "${AI_OPTIONAL_COMPONENTS[@]}"; do
    printf '  %-12s %s\n' "$component" "${transition[$component]}"
  done

  cat <<EOF

mise configuration applied
EOF
  mise_config_summary | sed 's/^/  /'
  printf '\nNetwork policy: %s\n' "$(fetch_policy_description)"

  if ((${#removal_paths[@]} > 0 || ${#removal_blockers[@]} > 0 || ${#stale_mise_specs[@]} > 0)); then
    printf '\nRemovals requested by --no-<component>\n'
    for spec in ${stale_mise_specs[@]+"${stale_mise_specs[@]}"}; do
      printf '  mise uninstall %s\n' "$spec"
    done
    for entry in ${removal_paths[@]+"${removal_paths[@]}"}; do
      entry_path="${entry#*|}"
      printf '  delete %s (%s)\n' "${entry_path%%|*}" "${entry##*|}"
    done
    for blocker in ${removal_blockers[@]+"${removal_blockers[@]}"}; do
      printf '  REFUSED, manual action required -- %s\n' "$blocker"
    done
    if ((${#removal_paths[@]} > 0 || ${#stale_mise_specs[@]} > 0)); then
      printf '  (an apply run confirms this first, or requires --non-interactive)\n'
    fi
  fi

  cat <<EOF

Steps:
  1. Write $conf_file
     (untracked, machine-local; not part of the always-installed mise config)
     Declares: npm:@anthropic-ai/claude-code, herdr$([[ "$install_codex" == "true" ]] && printf ', npm:@openai/codex')$([[ "$install_gnhf" == "true" ]] && printf ', npm:gnhf')$([[ "$install_firstmate" == "true" ]] && printf ',\n     npm:gh-axi, npm:chrome-devtools-axi, npm:tasks-axi, npm:quota-axi')$([[ "$install_lavish_axi" == "true" ]] && printf ', npm:lavish-axi')$([[ "$install_backpass" == "true" ]] && printf ',\n     npm:backpass, npm:acpx')
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
     Deliberately rolling on the upstream default branch; the resolved commit
     is recorded in $state_file. Requires 'gh', 'tmux', and 'jq' (Herdr is
     available as an alternative crew backend once installed above). Does not
     register any project or authenticate GitHub; see README.md.

  $((step + 1)). Install Treehouse (worktree isolation for FirstMate crewmates)
     $treehouse_install_script -> $treehouse_target
     Staged to a private temporary file, validated, then executed and
     verified; the digest that ran is recorded. Rerun --firstmate to update.

  $((step + 2)). Install No Mistakes (local validation gate before a push)
     $no_mistakes_install_script -> $no_mistakes_target
     Staged, validated, executed and verified the same way. Does not run
     'no-mistakes init' in any repository for you.
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

# --- Apply ------------------------------------------------------------------

require_command git

mise_command="$(resolve_mise_command || true)"
[[ -n "$mise_command" ]] || die "Required command not found: mise"

# Do not inherit the caller's possibly stale pre-Zsh PATH. This is shared by
# every AI component, including the own-script tools in ~/.local/bin.
establish_user_tool_environment

if [[ "$install_firstmate" == "true" ]]; then
  require_command gh
  require_command tmux
  require_command jq
  require_command curl
fi

if ((${#removal_blockers[@]} > 0)); then
  for blocker in "${removal_blockers[@]}"; do
    warn "Cannot prove this repository owns the target: $blocker"
  done
  die "Refusing to remove a component whose ownership cannot be proved. Inspect the paths above and remove them yourself if you still want them gone; nothing was changed."
fi

if ((${#removal_paths[@]} > 0 || ${#stale_mise_specs[@]} > 0)); then
  warn "This run removes previously installed AI components:"
  for spec in ${stale_mise_specs[@]+"${stale_mise_specs[@]}"}; do
    warn "  mise uninstall $spec"
  done
  for entry in ${removal_paths[@]+"${removal_paths[@]}"}; do
    entry_path="${entry#*|}"
    warn "  delete ${entry_path%%|*} (${entry##*|})"
  done
  if [[ "$interactive" == "true" ]]; then
    confirm 'Remove these AI components?' ||
      die "Removal declined; nothing was changed."
  else
    warn "Proceeding on the --non-interactive acknowledgement."
  fi
fi

info "Writing $conf_file"
ensure_dir "$conf_dir"
{
  printf '%s\n' "$conf_marker"
  printf '# Safe to delete; rerun the AI profile installer to recreate it.\n'
  printf '# Not tracked by the dotfiles repository.\n'
  printf '\n'
  printf '[tools]\n'
  # Claude Code's npm package uses postinstall to link its platform-native
  # optional dependency. mise otherwise disables npm lifecycle scripts.
  printf '"npm:@anthropic-ai/claude-code" = { version = "latest", npm_args = "--ignore-scripts=false --include=optional" }\n'
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
  if [[ "$install_lavish_axi" == "true" ]]; then
    printf '"npm:lavish-axi" = "latest"\n'
  fi
  if [[ "$install_backpass" == "true" ]]; then
    printf '"npm:backpass" = "latest"\n'
    printf '"npm:acpx" = "latest"\n'
  fi
} | atomic_write_file "$conf_file"

for spec in ${stale_mise_specs[@]+"${stale_mise_specs[@]}"}; do
  info "Removing the no-longer-selected mise tool: $spec"
  run_mise "$mise_command" uninstall "$spec" ||
    warn "mise could not uninstall $spec; it is no longer declared and will not be reinstalled."
done

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
if [[ "$install_lavish_axi" == "true" ]]; then
  mise_tools_msg+=", lavish-axi"
fi
if [[ "$install_backpass" == "true" ]]; then
  mise_tools_msg+=", backpass, and acpx"
fi
info "Installing $mise_tools_msg via mise"
if [[ "${DOTFILES_VERBOSE:-false}" == "true" ]]; then
  mise_config_summary | while IFS= read -r summary_line; do
    info "  mise $summary_line"
  done
fi
run_mise "$mise_command" --yes install
establish_user_tool_environment

claude_health_check() {
  run_mise "$mise_command" exec -- claude --version
}

diagnose_claude_npm_settings() {
  local ignore_scripts omit

  ignore_scripts="$(run_mise "$mise_command" exec -- npm config get ignore-scripts 2>/dev/null || printf 'unavailable')"
  omit="$(run_mise "$mise_command" exec -- npm config get omit 2>/dev/null || printf 'unavailable')"

  warn "npm settings while Claude Code was installed: ignore-scripts=${ignore_scripts:-unset}; omit=${omit:-unset}"
  if [[ -n "${NPM_CONFIG_IGNORE_SCRIPTS:-}" || -n "${NPM_CONFIG_OMIT:-}" ]]; then
    warn "npm environment overrides are set: NPM_CONFIG_IGNORE_SCRIPTS=${NPM_CONFIG_IGNORE_SCRIPTS:-unset}; NPM_CONFIG_OMIT=${NPM_CONFIG_OMIT:-unset}"
  fi
  warn "The Claude-only mise declaration explicitly enables lifecycle scripts and optional dependencies; global npm configuration was not changed."
}

claude_output=""
if ! claude_output="$(claude_health_check 2>&1)"; then
  if [[ "$claude_output" == *"claude native binary not installed"* ]]; then
    warn "Claude Code's wrapper exists, but its platform-native binary is missing."
    diagnose_claude_npm_settings
    info "Repairing only the mise-managed Claude Code installation (one attempt)"
    run_mise "$mise_command" uninstall npm:@anthropic-ai/claude-code
    run_mise "$mise_command" --yes install npm:@anthropic-ai/claude-code
    establish_user_tool_environment

    if ! claude_output="$(claude_health_check 2>&1)"; then
      printf '%s\n' "$claude_output" >&2
      die "Claude Code is still broken after one repair attempt. Manual recovery:\n  mise uninstall npm:@anthropic-ai/claude-code\n  mise install"
    fi
    success "Claude Code native installation repaired: $claude_output"
  else
    printf '%s\n' "$claude_output" >&2
    die "Claude Code failed its health check ('claude --version'); automatic repair is limited to the native-binary-missing failure"
  fi
fi

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

# verify_installed_binary <name> <target>: the immediate post-install check for
# a tool installed by someone else's script. A missing, non-regular, unowned,
# non-executable, or non-launching target fails here -- at the component that
# is responsible for it -- rather than several steps later.
verify_installed_binary() {
  local name="$1" target="$2"

  [[ -e "$target" ]] || die "$name did not install its expected target: $target"
  [[ -f "$target" && ! -L "$target" ]] ||
    die "$name target is not a regular file: $target"
  [[ -O "$target" ]] ||
    die "$name target is not owned by the invoking user: $target"
  [[ -x "$target" ]] || die "$name target is not executable: $target"

  # A harmless self-description proves the binary actually runs. Upstreams
  # differ on which flag they support, so either is accepted; neither working
  # means the install did not produce a usable tool.
  if "$target" --version >/dev/null 2>&1 || "$target" --help >/dev/null 2>&1; then
    return 0
  fi
  die "$name installed at $target but neither '--version' nor '--help' ran successfully"
}

# install_staged_script <name> <url> <target> [expected-sha256]
#
# Replaces the old 'curl ... | sh' pipeline, whose exit status was the
# consumer shell's and could report success after the download failed. The
# content is staged into a mode-0600 file under a private directory, rejected
# unless it survives every validation, executed only then, removed immediately
# afterwards, and the installed target is verified before the caller may record
# any state. The digest of the script that actually ran is published in
# INSTALL_STAGED_SCRIPT_DIGEST rather than on stdout, so this never has to run
# inside a command substitution: in a subshell neither the staging-cleanup
# bookkeeping nor a die() would reach the installer process.
INSTALL_STAGED_SCRIPT_DIGEST=""
install_staged_script() {
  local name="$1" url="$2" target="$3" expected="${4:-}"
  local work_dir staged digest

  work_dir="$(mktemp -d)" || die "Could not create a staging directory for $name"
  chmod 700 -- "$work_dir"
  AI_STAGING_DIRS+=("$work_dir")
  staged="$work_dir/install.sh"

  info "Staging the $name installer"
  if ! (
    set -euo pipefail
    fetch_to_file "$url" "$staged" "the $name installer"
    fetch_assert_shell_script "$staged" "the $name installer"
    [[ -z "$expected" ]] || fetch_verify_sha256 "$staged" "$expected" "the $name installer"
  ); then
    rm -rf -- "$work_dir"
    die "The $name installer was not downloaded and validated; nothing was executed."
  fi

  digest="$(fetch_sha256 "$staged")" || {
    rm -rf -- "$work_dir"
    die "Could not record the digest of the $name installer."
  }

  info "Installing $name: $target"
  ensure_dir "$(dirname "$target")"
  # Every upstream script here picks the first of ~/.local/bin or /usr/local/bin
  # that is on PATH, silently escalating to sudo for the latter. Putting the
  # target directory first guarantees a user-owned install with no unexpected
  # privilege escalation. The staged file is run by an explicit interpreter, so
  # a missing or hostile shebang cannot choose one.
  if ! PATH="$(dirname "$target"):$PATH" sh "$staged"; then
    rm -rf -- "$work_dir"
    die "The $name installer failed."
  fi
  rm -rf -- "$work_dir"

  verify_installed_binary "$name" "$target"
  INSTALL_STAGED_SCRIPT_DIGEST="$digest"
}

firstmate_state="disabled"
firstmate_source="not-recorded"
firstmate_commit="not-recorded"
treehouse_state="disabled"
treehouse_source="not-recorded"
treehouse_digest="not-recorded"
treehouse_target_digest="not-recorded"
no_mistakes_state="disabled"
no_mistakes_source="not-recorded"
no_mistakes_digest="not-recorded"
no_mistakes_target_digest="not-recorded"

if [[ "$install_firstmate" == "true" ]]; then
  # FirstMate has no release artifact and no package-manager upstream, so this
  # is a deliberately rolling channel rather than a pin. What makes that
  # accountable is the recorded commit: the profile state always says exactly
  # which revision is installed, and 'git -C ~/.local/share/firstmate checkout
  # <commit>' returns to it. Rerunning --firstmate is the update command.
  if [[ -d "$firstmate_dir/.git" ]]; then
    info "Updating FirstMate: $firstmate_dir"
    # network-source: firstmate-repo
    git -C "$firstmate_dir" pull --ff-only
  else
    info "Cloning FirstMate: $firstmate_repo"
    ensure_dir "$(dirname "$firstmate_dir")"
    # network-source: firstmate-repo
    git clone "$firstmate_repo" "$firstmate_dir"
  fi
  firstmate_state="cloned"
  firstmate_source="$firstmate_repo"
  firstmate_commit="$(git -C "$firstmate_dir" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$firstmate_commit" ]] ||
    die "FirstMate was cloned but its resolved commit could not be read: $firstmate_dir"
  info "FirstMate resolved commit: $firstmate_commit"

  # network-source: treehouse-installer
  install_staged_script Treehouse \
    "$treehouse_install_script" "$treehouse_target" "$treehouse_expected_sha256"
  treehouse_digest="$INSTALL_STAGED_SCRIPT_DIGEST"
  treehouse_state="installed"
  treehouse_source="$treehouse_install_script"
  treehouse_target_digest="$(fetch_sha256 "$treehouse_target")"
  info "Treehouse installer digest: $treehouse_digest"
  info "Treehouse installed binary digest: $treehouse_target_digest"

  # network-source: no-mistakes-installer
  install_staged_script "No Mistakes" \
    "$no_mistakes_install_script" "$no_mistakes_target" "$no_mistakes_expected_sha256"
  no_mistakes_digest="$INSTALL_STAGED_SCRIPT_DIGEST"
  no_mistakes_state="installed"
  no_mistakes_source="$no_mistakes_install_script"
  no_mistakes_target_digest="$(fetch_sha256 "$no_mistakes_target")"
  info "No Mistakes installer digest: $no_mistakes_digest"
  info "No Mistakes installed binary digest: $no_mistakes_target_digest"
else
  # An explicit removal, already confirmed and already proved owned above.
  for entry in ${removal_paths[@]+"${removal_paths[@]}"}; do
    removal_kind="${entry%%|*}"
    removal_path="${entry#*|}"
    removal_path="${removal_path%%|*}"
    info "Removing ${entry##*|}: $removal_path"
    case "$removal_kind" in
    tree) rm -rf -- "$removal_path" ;;
    file) rm -f -- "$removal_path" ;;
    *) die "Unknown removal kind: $removal_kind" ;;
    esac
  done
fi

info "Recording the AI profile in $state_file"
ensure_dir "$(dirname "$state_file")"
write_ai_state() {
  local status="$1"

  {
    printf 'profile=ai\n'
    printf 'requested=%s\n' "$requested_summary"
    printf 'claude_code=mise-npm\n'
    printf 'herdr=mise\n'
    if [[ "$install_codex" == "true" ]]; then
      printf 'codex=mise-npm\n'
    else
      printf 'codex=disabled\n'
    fi
    printf 'firstmate=%s\n' "$firstmate_state"
    printf 'firstmate_source=%s\n' "$firstmate_source"
    printf 'firstmate_commit=%s\n' "$firstmate_commit"
    printf 'treehouse=%s\n' "$treehouse_state"
    printf 'treehouse_source=%s\n' "$treehouse_source"
    printf 'treehouse_digest=%s\n' "$treehouse_digest"
    printf 'treehouse_target_digest=%s\n' "$treehouse_target_digest"
    printf 'no_mistakes=%s\n' "$no_mistakes_state"
    printf 'no_mistakes_source=%s\n' "$no_mistakes_source"
    printf 'no_mistakes_digest=%s\n' "$no_mistakes_digest"
    printf 'no_mistakes_target_digest=%s\n' "$no_mistakes_target_digest"
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
    if [[ "$install_lavish_axi" == "true" ]]; then
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
  } | profile_state_write_content "$state_file" ai "$status"
}

# Only a verified profile is ever committed as installed. Everything above has
# already failed loudly on its own component, so reaching this point means each
# selected component exists and launches; the state file records the observed
# result, and the profile-level verifier is the final gate.
write_ai_state applying

info "Validating the AI profile"
if "$DOTFILES_ROOT/common/verify-ai.sh"; then
  profile_state_set_status "$state_file" ai installed
  success "AI profile installed"
else
  profile_state_set_status "$state_file" ai failed
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
  • FirstMate tracks its upstream default branch deliberately. The installed
    revision is $firstmate_commit; rerun './common/install-ai.sh --firstmate'
    to update, or 'git -C $firstmate_dir checkout <commit>' to pin it locally.
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
