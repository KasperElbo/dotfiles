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
firstmate_backend_file="$firstmate_dir/config/backend"
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
claude_settings_file="$HOME/.claude/settings.json"
# The keys that stop Claude Code from installing a second copy of itself. Both,
# because only builds new enough to read DISABLE_UPDATES honour it, while every
# build reads DISABLE_AUTOUPDATER. See docs/profiles/ai.md.
CLAUDE_UPDATE_ENV_KEYS=(DISABLE_UPDATES DISABLE_AUTOUPDATER)
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
paths, so one edit updates every harness. See docs/profiles/ai.md.

Options:
  --codex            Also install the OpenAI Codex CLI
  --firstmate        Also install FirstMate and every tool its own docs
                     list as required: Treehouse, No Mistakes, gh-axi,
                     chrome-devtools-axi, lavish-axi, tasks-axi, and
                     quota-axi (requires 'gh', 'tmux', and 'jq'; see
                     docs/profiles/ai.md)
  --gnhf             Also install GNHF, an unattended overnight agent
                     orchestrator (see docs/profiles/ai.md -- read it before
                     use; it runs an agent unsupervised)
  --backpass         Also install backpass, which proposes evidence-backed
                     edits to AGENTS.md/CLAUDE.md from agent session
                     transcripts, gated behind mandatory human review
                     (independent of --firstmate; see docs/profiles/ai.md)
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
script that actually ran, and the path and digest of the binary it produced,
recorded, and are updated by rerunning --firstmate.
This installer never runs 'gh-axi setup hooks' or 'lavish-axi setup hooks'
(optional agent session-start hooks), 'no-mistakes init' (per-repository),
or 'backpass init'/'backpass apply' (per-repository, and the latter is the
only command that writes anything) on your behalf -- see
docs/profiles/ai.md for those manual, deliberate steps. Authenticate each tool
interactively (see the same guide); this installer never stores or requests
credentials, and never
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

# One rendering of a command path, naming what it resolves to only when that
# is somewhere else, so a launcher layout is visible in every message.
describe_binary_path() {
  local target="$1" resolved="${2:-}"

  if [[ -n "$resolved" && "$resolved" != "$target" ]]; then
    printf '%s -> %s\n' "$target" "$resolved"
  else
    printf '%s\n' "$target"
  fi
}

# --- Provenance-proved ownership -------------------------------------------
#
# Removal deletes nothing it cannot prove it installed. Each check answers a
# single question: is this exact artifact still the one recorded in the profile
# state? A user-replaced binary, a checkout repointed at another remote, or a
# component installed before provenance was recorded all fail the check, and
# the installer reports manual action instead of deleting anything.

owned_reason=""

# The file a proved-owned command resolves to, so the caller removes the binary
# an upstream installed and not just the launcher that points at it.
owned_binary_path=""

own_check_script_binary() {
  local name="$1" target="$2" digest_key="$3" path_key="$4"
  local recorded actual resolved recorded_path

  owned_reason=""
  owned_binary_path=""
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    owned_reason="already absent"
    return 1
  fi

  resolved="$(resolve_existing_path "$target" 2>/dev/null || true)"
  if [[ -z "$resolved" || ! -f "$resolved" ]]; then
    owned_reason="$target does not resolve to a regular file"
    return 1
  fi

  # A launcher symlink is a layout this repository accepts from an upstream
  # but never infers: the binary behind it is deleted only when it is still
  # the exact file recorded at install time. Without that record, following
  # the link would mean trusting wherever it happens to point today.
  if [[ -L "$target" ]]; then
    recorded_path="$(state_value "$path_key" || true)"
    if [[ -z "$recorded_path" || "$recorded_path" == not-recorded ]]; then
      owned_reason="$target is a symlink and no installed path was recorded for $name; rerun the AI installer before removing it"
      return 1
    fi
    if [[ "$recorded_path" != "$resolved" ]]; then
      owned_reason="$target now resolves to $resolved, not the recorded $recorded_path"
      return 1
    fi
  fi

  recorded="$(state_value "$digest_key" || true)"
  if [[ -z "$recorded" || "$recorded" == not-recorded ]]; then
    owned_reason="no digest was recorded for $name when it was installed"
    return 1
  fi

  actual="$(fetch_sha256 "$resolved" 2>/dev/null || true)"
  if [[ "$actual" != "$recorded" ]]; then
    owned_reason="$(describe_binary_path "$target" "$resolved") no longer matches the recorded digest (expected $recorded, found ${actual:-unreadable})"
    return 1
  fi
  owned_binary_path="$resolved"
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

  # The backend selection this installer writes lives inside the checkout, so
  # it is our own artifact rather than a user modification. --untracked-files=all
  # keeps Git from collapsing it into a bare 'config/' entry, so exactly that
  # one path can be discounted and anything else still refuses the removal.
  local worktree_state
  worktree_state="$(
    git -C "$firstmate_dir" status --porcelain --untracked-files=all 2>/dev/null ||
      printf 'unreadable'
  )"
  worktree_state="$(
    printf '%s\n' "$worktree_state" |
      grep -v -x -F "?? ${firstmate_backend_file#"$firstmate_dir"/}" || true
  )"
  if [[ -n "${worktree_state//[[:space:]]/}" ]]; then
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
  for entry in "treehouse:$treehouse_target:treehouse_target_digest:treehouse_target_path" \
    "no-mistakes:$no_mistakes_target:no_mistakes_target_digest:no_mistakes_target_path"; do
    IFS=: read -r own_name own_target own_key own_path_key <<<"$entry"
    if own_check_script_binary "$own_name" "$own_target" "$own_key" "$own_path_key"; then
      # Each deleted path is listed in its own right, so --dry-run and the
      # confirmation name the upstream's own directory rather than hiding it
      # behind the launcher that will be removed with it.
      removal_paths+=("file|$own_target|$own_name")
      [[ ! -L "$own_target" ]] ||
        removal_paths+=("binary|$owned_binary_path|$own_name binary")
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

  3. Declare ${CLAUDE_UPDATE_ENV_KEYS[*]} = "1" under the "env" key of
     $claude_settings_file
     so Claude Code does not install a second copy of itself into the
     mise-managed Node prefix. Merged into whatever is already there; every
     other key is preserved. A file that does not parse as JSON, or whose
     "env" is not an object, is reported and left untouched.
EOF

  cat <<EOF

  4. Link the shared agent-instructions file (common/assets/AGENTS.md,
     mirrored from KasperElbo/dotfiles-nix's home/AGENTS.md) into every
     harness's global instructions path:
     $claude_md_target
     $codex_agents_target
     $opencode_agents_target
     An existing file or symlink pointing elsewhere at any of these paths
     is left untouched, never overwritten.
EOF

  step=5
  if [[ "$install_firstmate" == "true" ]]; then
    cat <<EOF

  $step. Clone or update FirstMate
     $firstmate_repo -> $firstmate_dir
     Deliberately rolling on the upstream default branch; the resolved commit
     is recorded in $state_file. Configure $firstmate_backend_file to 'herdr'
     so a normal coordinator launch uses Herdr without an FM_BACKEND prefix.
     Requires 'gh', 'tmux', and 'jq'. Does not register any project or
     authenticate GitHub; see docs/profiles/ai.md.

  $((step + 1)). Install Treehouse (worktree isolation for FirstMate crewmates)
     $treehouse_install_script -> $treehouse_target
     Staged to a private temporary file, validated, then executed and
     verified; the digest that ran is recorded. The command path above is
     what this installer promises; an upstream that instead installs into
     its own directory and leaves a launcher symlink there is accepted, and
     the file the command resolves to is what gets recorded and verified.
     Rerun --firstmate to update.

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
     'backpass apply' in any repository for you; see
     docs/profiles/ai.md for the manual next steps and its model-routing
     defaults.
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
# Claude Code's own settings file is the only place an update block survives a
# launch this repository did not start; merging into it needs a JSON reader.
# jq is a baseline package on every platform that offers the AI profile.
require_command jq

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

# Install time is when the deterministic context is built; run_mise only reads
# it (see lib/common.sh). Here rather than beside the mise lookup above, so a
# missing prerequisite is still reported by its own require_command first.
mise_prepare_context >/dev/null

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

# Claude Code decides how it was installed by looking at its own executable
# path. mise's npm backend puts the package under
# .../npm-anthropic-ai-claude-code/<version>/lib/node_modules/@anthropic-ai/...,
# which contains /node_modules/@anthropic-ai/, so the tool reads itself as an
# ordinary global npm install and updates itself with `npm install -g`. npm's
# global prefix for the mise-managed Node is the Node installation directory,
# not the backend prefix mise installed into, so that update never replaces the
# mise copy: it adds a second one beside it, which then shadows the first.
#
# `zsh/.zshenv` exports the same keys, but a shell-exported variable only
# reaches processes descended from a top-level Zsh. Claude Code's own settings
# file is read by the tool however it was launched, which is the property that
# makes the block hold. See docs/profiles/ai.md.
#
# Merged, never overwritten and never symlinked: Claude Code writes to this
# file itself, and so does the user. A file that does not parse, or whose `env`
# is not an object, is reported and left exactly as it is -- guessing at the
# intent of a configuration file this repository did not write is the one thing
# an ownership model must not do.
claude_update_settings_filter() {
  local key
  local filter='.env = ((.env // {})'

  for key in "${CLAUDE_UPDATE_ENV_KEYS[@]}"; do
    filter+=" + {\"$key\": \"1\"}"
  done
  printf '%s)\n' "$filter"
}

claude_update_settings_already_declared() {
  local file="$1" key
  for key in "${CLAUDE_UPDATE_ENV_KEYS[@]}"; do
    jq -e --arg key "$key" '(.env[$key] // null) == "1"' "$file" >/dev/null 2>&1 ||
      return 1
  done
}

write_claude_update_settings() {
  local file="$claude_settings_file"
  local filter merged

  ensure_dir "$(dirname "$file")"
  filter="$(claude_update_settings_filter)"

  if [[ -L "$file" ]]; then
    warn "Keeping existing symlink, not writing Claude Code's update settings: $file"
    warn "Claude Code rewrites this file itself; declare ${CLAUDE_UPDATE_ENV_KEYS[*]} in its target by hand."
    return
  fi

  if [[ ! -e "$file" ]]; then
    jq --null-input --sort-keys "{} | $filter" | atomic_write_file "$file"
    info "Wrote $file (${CLAUDE_UPDATE_ENV_KEYS[*]})"
    return
  fi

  if ! jq -e . "$file" >/dev/null 2>&1; then
    warn "Keeping $file untouched: it is not valid JSON."
    warn "Declare ${CLAUDE_UPDATE_ENV_KEYS[*]} = \"1\" under its \"env\" key by hand, or Claude Code will keep reinstalling itself outside mise."
    return
  fi

  if ! jq -e 'if has("env") then (.env | type) == "object" else true end' \
    "$file" >/dev/null 2>&1; then
    warn "Keeping $file untouched: its \"env\" key is not an object."
    warn "Declare ${CLAUDE_UPDATE_ENV_KEYS[*]} = \"1\" under \"env\" by hand."
    return
  fi

  if claude_update_settings_already_declared "$file"; then
    info "Already declared in $file: ${CLAUDE_UPDATE_ENV_KEYS[*]}"
    return
  fi

  merged="$(jq --sort-keys "$filter" "$file")"
  printf '%s\n' "$merged" | atomic_write_file "$file"
  info "Declared ${CLAUDE_UPDATE_ENV_KEYS[*]} in $file (other keys preserved)"
}

info "Keeping Claude Code's updater out of the mise-managed Node prefix"
write_claude_update_settings

# link_agent_instructions <target>: points a harness's global instructions
# path at this repository's tracked common/assets/AGENTS.md, so editing one
# file updates Claude Code, Codex, and OpenCode together. Never overwrites an
# existing file or a symlink already pointing elsewhere -- an explicit,
# harness-specific instructions file a user put there themselves always wins.
link_agent_instructions() {
  local target="$1"

  ensure_dir "$(dirname "$target")"

  if [[ -L "$target" ]]; then
    # Canonicalized on both sides: agents_source is built from DOTFILES_ROOT,
    # which is logical, while a resolved link is physical, so a link this
    # repository already owns must still compare equal under a checkout reached
    # through a symlink.
    if resolved_link_matches "$target" "$agents_source"; then
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

# remove_emptied_install_dirs <removed-file>: prune the private directory an
# upstream created for its own binary once that binary is gone. Only empty
# directories strictly inside $HOME are pruned, and rmdir is what does it, so a
# directory holding anything else -- an upstream's own configuration, a second
# tool -- survives untouched. Directories this repository or the user owns for
# other reasons ($HOME itself, and the ~/.local/bin the command lived on) are
# never candidates.
remove_emptied_install_dirs() {
  local directory home_canonical launcher launcher_dir

  home_canonical="$(resolve_existing_path "$HOME" 2>/dev/null || printf '%s' "$HOME")"
  directory="$(dirname -- "$1")"

  # Both spellings of every boundary are compared, because the path being
  # pruned is canonical while $HOME and the command paths are as configured:
  # on a host where either contains a symlinked component, comparing only one
  # spelling would let a protected directory through.
  while [[ "$directory" == "$HOME"/?* || "$directory" == "$home_canonical"/?* ]]; do
    for launcher in "$treehouse_target" "$no_mistakes_target"; do
      launcher_dir="$(dirname -- "$launcher")"
      [[ "$directory" != "$launcher_dir" ]] || return 0
      [[ "$directory" != "$(resolve_existing_path "$launcher_dir" 2>/dev/null || printf '%s' "$launcher_dir")" ]] ||
        return 0
    done
    rmdir -- "$directory" 2>/dev/null || return 0
    info "Removed the emptied upstream directory: $directory"
    directory="$(dirname -- "$directory")"
  done
}

# verify_installed_binary <name> <command-path>: the immediate post-install
# check for a tool installed by someone else's script. A missing, unresolvable,
# unowned, non-executable, or non-launching command fails here -- at the
# component that is responsible for it -- rather than several steps later.
#
# The command path is where this repository promised the tool would be; the
# layout behind it belongs to the upstream installer. No Mistakes on
# darwin/arm64 puts its binary in ~/.no-mistakes/bin and leaves a launcher
# symlink on PATH, while Treehouse writes the binary straight to the command
# path. Demanding a regular file *at the command path* asserted one upstream's
# layout rather than the property this repository actually needs, and rejected
# the only supported macOS install of a component it advertises. So the chain
# is resolved first and every remaining question is asked of the file it names.
#
# The resolved path is published in INSTALL_VERIFIED_BINARY_PATH: it is what
# gets hashed for provenance and what a later removal has to delete, because
# deleting a launcher symlink alone would leave the tool installed.
INSTALL_VERIFIED_BINARY_PATH=""
verify_installed_binary() {
  local name="$1" target="$2" resolved

  INSTALL_VERIFIED_BINARY_PATH=""
  [[ -e "$target" || -L "$target" ]] ||
    die "$name did not install its expected target: $target"

  resolved="$(resolve_existing_path "$target" 2>/dev/null || true)"
  [[ -n "$resolved" ]] ||
    die "$name target does not resolve to an existing file: $target"
  [[ -f "$resolved" ]] ||
    die "$name target is not a regular file: $(describe_binary_path "$target" "$resolved")"
  [[ -O "$resolved" ]] ||
    die "$name target is not owned by the invoking user: $(describe_binary_path "$target" "$resolved")"
  [[ -x "$resolved" ]] ||
    die "$name target is not executable: $(describe_binary_path "$target" "$resolved")"

  # A harmless self-description proves the binary actually runs. Upstreams
  # differ on which flag they support, so either is accepted; neither working
  # means the install did not produce a usable tool.
  if "$target" --version >/dev/null 2>&1 || "$target" --help >/dev/null 2>&1; then
    INSTALL_VERIFIED_BINARY_PATH="$resolved"
    return 0
  fi
  die "$name installed at $target but neither '--version' nor '--help' ran successfully"
}

# stage_api_credential <staging-dir>: prints the CURL_HOME the staged installer
# should run with, having prepared a credential there when one is available.
#
# Both of these upstreams resolve their own latest release through
# api.github.com. Anonymously that is 60 requests an hour *per address*, shared
# with everyone else on it, and on a hosted CI runner other tenants routinely
# spend it: the install then fails inside the upstream script with a bare 403,
# saying nothing about this repository.
#
# A CI job has a token for exactly that, but which variable an upstream script
# reads is the upstream's choice, and these read none: an install and a rerun a
# minute apart, both with GITHUB_TOKEN exported, resolved and then failed --
# which an authenticated caller's 5000 an hour cannot do. So the credential is
# offered where any curl-based installer finds it without cooperating, in the
# one form curl scopes by host: a netrc naming api.github.com and nothing else.
# Every other host the script contacts is sent no credential.
#
# This widens no trust boundary. The token is already in the environment of
# these scripts wherever CI exports it; this only makes it usable for the
# request it was exported for. It lives in the 0700 staging directory, is
# written 0600, and is deleted with that directory when the script returns.
# With no token in the environment -- every workstation install -- nothing is
# written and the script runs exactly as it did before.
stage_api_credential() {
  local work_dir="$1"
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

  if [[ -n "$token" ]]; then
    # umask rather than a later chmod: the file is never briefly readable by
    # anyone else on a shared machine.
    (
      umask 077
      printf 'machine api.github.com login x-access-token password %s\n' \
        "$token" >"$work_dir/netrc"
      printf 'netrc-file = "%s/netrc"\nnetrc\n' "$work_dir" >"$work_dir/.curlrc"
    ) || return 1
  fi

  printf '%s\n' "$work_dir"
}

# install_staged_script <name> <url> <target> [expected-sha256]
#
# Replaces the old 'curl ... | sh' pipeline, whose exit status was the
# consumer shell's and could report success after the download failed. The
# content is staged into a mode-0600 file under a private directory, rejected
# unless it survives every validation, executed only then, removed immediately
# afterwards, and the installed target is verified before the caller may record
# any state. The digest of the script that actually ran is published in
# INSTALL_STAGED_SCRIPT_DIGEST, and the file the installed command resolves to
# in INSTALL_STAGED_SCRIPT_TARGET_PATH, rather than on stdout, so this never
# has to run inside a command substitution: in a subshell neither the
# staging-cleanup bookkeeping nor a die() would reach the installer process.
INSTALL_STAGED_SCRIPT_DIGEST=""
INSTALL_STAGED_SCRIPT_TARGET_PATH=""
install_staged_script() {
  local name="$1" url="$2" target="$3" expected="${4:-}"
  local work_dir staged digest curl_home

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
  curl_home="$(stage_api_credential "$work_dir")" || {
    rm -rf -- "$work_dir"
    die "Could not prepare the API credential for the $name installer."
  }
  [[ ! -f "$work_dir/netrc" ]] ||
    info "Offering the GitHub API credential to $name for api.github.com only"
  if ! PATH="$(dirname "$target"):$PATH" CURL_HOME="$curl_home" sh "$staged"; then
    rm -rf -- "$work_dir"
    die "The $name installer failed."
  fi
  rm -rf -- "$work_dir"

  verify_installed_binary "$name" "$target"
  INSTALL_STAGED_SCRIPT_DIGEST="$digest"
  INSTALL_STAGED_SCRIPT_TARGET_PATH="$INSTALL_VERIFIED_BINARY_PATH"
}

firstmate_state="disabled"
firstmate_source="not-recorded"
firstmate_commit="not-recorded"
treehouse_state="disabled"
treehouse_source="not-recorded"
treehouse_digest="not-recorded"
treehouse_target_digest="not-recorded"
treehouse_target_path="not-recorded"
no_mistakes_state="disabled"
no_mistakes_source="not-recorded"
no_mistakes_digest="not-recorded"
no_mistakes_target_digest="not-recorded"
no_mistakes_target_path="not-recorded"

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

  info "Configuring FirstMate to use Herdr by default: $firstmate_backend_file"
  ensure_dir "$(dirname "$firstmate_backend_file")"
  printf 'herdr\n' | atomic_write_file "$firstmate_backend_file"

  # network-source: treehouse-installer
  install_staged_script Treehouse \
    "$treehouse_install_script" "$treehouse_target" "$treehouse_expected_sha256"
  treehouse_digest="$INSTALL_STAGED_SCRIPT_DIGEST"
  treehouse_state="installed"
  treehouse_source="$treehouse_install_script"
  # The file the command resolves to, which is the command path itself unless
  # this upstream installed elsewhere and linked. Both the digest below and a
  # later removal are about that file, never about the launcher.
  treehouse_target_path="$INSTALL_STAGED_SCRIPT_TARGET_PATH"
  treehouse_target_digest="$(fetch_sha256 "$treehouse_target_path")"
  info "Treehouse installer digest: $treehouse_digest"
  info "Treehouse installed binary: $(describe_binary_path "$treehouse_target" "$treehouse_target_path")"
  info "Treehouse installed binary digest: $treehouse_target_digest"

  # network-source: no-mistakes-installer
  install_staged_script "No Mistakes" \
    "$no_mistakes_install_script" "$no_mistakes_target" "$no_mistakes_expected_sha256"
  no_mistakes_digest="$INSTALL_STAGED_SCRIPT_DIGEST"
  no_mistakes_state="installed"
  no_mistakes_source="$no_mistakes_install_script"
  no_mistakes_target_path="$INSTALL_STAGED_SCRIPT_TARGET_PATH"
  no_mistakes_target_digest="$(fetch_sha256 "$no_mistakes_target_path")"
  info "No Mistakes installer digest: $no_mistakes_digest"
  info "No Mistakes installed binary: $(describe_binary_path "$no_mistakes_target" "$no_mistakes_target_path")"
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
    binary)
      rm -f -- "$removal_path"
      remove_emptied_install_dirs "$removal_path"
      ;;
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
    printf 'treehouse_target_path=%s\n' "$treehouse_target_path"
    printf 'no_mistakes=%s\n' "$no_mistakes_state"
    printf 'no_mistakes_source=%s\n' "$no_mistakes_source"
    printf 'no_mistakes_digest=%s\n' "$no_mistakes_digest"
    printf 'no_mistakes_target_digest=%s\n' "$no_mistakes_target_digest"
    printf 'no_mistakes_target_path=%s\n' "$no_mistakes_target_path"
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
  • FirstMate is cloned and configured to use Herdr by default via
    $firstmate_backend_file. Start the coordinator with:
      cd $firstmate_dir && claude
    Run 'gh auth login' first if you have not, then register projects through
    the coordinator as documented in $firstmate_dir/README.md.
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
