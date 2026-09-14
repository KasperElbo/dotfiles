#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/verify.sh"
# shellcheck source=lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/profile-state.sh"

verify_reset

state_file="$XDG_CONFIG_HOME/dotfiles/ai.conf"
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"
treehouse_target="$HOME/.local/bin/treehouse"
no_mistakes_target="$HOME/.local/bin/no-mistakes"
agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_md_target="$HOME/.claude/CLAUDE.md"
codex_agents_target="$codex_home/AGENTS.md"
opencode_agents_target="$XDG_CONFIG_HOME/opencode/AGENTS.md"

[[ -f "$state_file" ]] || {
  printf 'AI profile state is missing: %s\n' "$state_file" >&2
  exit 1
}

profile_state_validate_file "$state_file" ai || exit 1

codex_state="$(profile_state_read "$state_file" codex ai)"
firstmate_state="$(profile_state_read "$state_file" firstmate ai)"
treehouse_state="$(profile_state_read "$state_file" treehouse ai)"
no_mistakes_state="$(profile_state_read "$state_file" no_mistakes ai)"
lavish_axi_state="$(profile_state_read "$state_file" lavish_axi ai)"
gnhf_state="$(profile_state_read "$state_file" gnhf ai)"
backpass_state="$(profile_state_read "$state_file" backpass ai)"

# Capture the environment configured for a fresh interactive login before the
# verifier adds mise's shims to its own process. An explicit value remains
# supported for hermetic callers and tests.
if [[ -z "${VERIFY_CONFIGURED_LOGIN_PATH+x}" ]]; then
  VERIFY_CONFIGURED_LOGIN_PATH="$(
    zsh -lic 'printf "%s\\n" "$PATH"' 2>/dev/null || true
  )"
fi
VERIFY_CALLER_PATH="$PATH"
mise_command="$(resolve_mise_command || true)"
VERIFY_MISE_COMMAND="$mise_command"
mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
mise_shims_dir="${MISE_SHIMS_DIR:-$mise_data_dir/shims}"

# Verification has the same deterministic command environment as installation,
# even when called from a shell that predates the final Zsh configuration.
establish_user_tool_environment

check_mise_command_runs() {
  local name="$1"
  shift

  if [[ -n "$mise_command" ]] &&
    "$mise_command" exec -- "$name" "$@" >/dev/null 2>&1; then
    pass "$name launches successfully: $name $*"
  else
    fail "$name is installed but '$name $*' failed"
  fi
}

# check_own_script_owned <command> <target>: for a tool with no mise
# registry entry, confirms <target> exists and is executable, and that
# nothing else on PATH shadows it with a duplicate install.
check_own_script_owned() {
  local name="$1"
  local target="$2"
  local resolved

  if [[ -x "$target" ]]; then
    pass "$name: $target"
  else
    fail "$name is missing or not executable: $target"
    return
  fi

  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$resolved" ]] &&
    { [[ "$resolved" == "$target" ]] || [[ "$resolved" -ef "$target" ]]; }; then
    pass "$name on PATH resolves to the installed copy"
  elif [[ -n "$resolved" ]]; then
    fail "$name on PATH ($resolved) is not $target, a possible duplicate install"
  else
    warning "$target is not on PATH"
  fi
}

# Shared instruction files intentionally respect a pre-existing user-owned
# file/link. That conflict is a warning rather than a repository-owned
# invariant, but it must never be reported as verified ownership.
check_symlink_owned() {
  local label="$1"
  local target="$2"

  if [[ ! -e "$target" && ! -L "$target" ]]; then
    fail "$label is missing: $target"
    return
  fi

  if [[ ! -L "$target" ]]; then
    warning "$label ($target) is a plain file, not a symlink to $agents_source"
    return
  fi

  if [[ ! -e "$target" ]]; then
    warning "$label ($target) is a dangling symlink, not owned by this profile"
    return
  fi

  if [[ "$(verify_canonical_existing_path "$target" 2>/dev/null || true)" == \
    "$(verify_canonical_existing_path "$agents_source" 2>/dev/null || true)" ]]; then
    pass "$label: $target -> $agents_source"
  else
    warning "$label ($target) is a symlink pointing elsewhere, not $agents_source"
  fi
}

section "AI profile ownership (mise conf.d)"

if [[ -f "$conf_file" ]]; then
  pass "Untracked mise config present: $conf_file"
else
  fail "Untracked mise config missing: $conf_file"
fi

if grep -Fq '"npm:@anthropic-ai/claude-code"' "$conf_file" 2>/dev/null; then
  pass "Claude Code declared in $conf_file"
else
  fail "Claude Code not declared in $conf_file"
fi

if grep -Fq 'herdr' "$conf_file" 2>/dev/null; then
  pass "Herdr declared in $conf_file"
else
  fail "Herdr not declared in $conf_file"
fi

if [[ "$codex_state" == mise-npm ]]; then
  if grep -Fq '"npm:@openai/codex"' "$conf_file" 2>/dev/null; then
    pass "Codex declared in $conf_file"
  else
    fail "Codex not declared in $conf_file despite codex=mise-npm in $state_file"
  fi
fi

if [[ "$gnhf_state" == mise-npm ]]; then
  if grep -Fq '"npm:gnhf"' "$conf_file" 2>/dev/null; then
    pass "GNHF declared in $conf_file"
  else
    fail "GNHF not declared in $conf_file despite gnhf=mise-npm in $state_file"
  fi
fi

if [[ "$firstmate_state" == cloned ]]; then
  for entry in 'gh-axi:npm:gh-axi' \
    'chrome-devtools-axi:npm:chrome-devtools-axi' \
    'tasks-axi:npm:tasks-axi' \
    'quota-axi:npm:quota-axi'; do
    tool_label="${entry%%:*}"
    tool_decl="${entry#*:}"
    if grep -Fq "\"$tool_decl\"" "$conf_file" 2>/dev/null; then
      pass "$tool_label declared in $conf_file"
    else
      fail "$tool_label not declared in $conf_file despite firstmate=cloned in $state_file"
    fi
  done
fi

if [[ "$lavish_axi_state" == mise-npm ]]; then
  if grep -Fq '"npm:lavish-axi"' "$conf_file" 2>/dev/null; then
    pass "lavish-axi declared in $conf_file"
  else
    fail "lavish-axi not declared in $conf_file despite lavish_axi=mise-npm in $state_file"
  fi
fi

if [[ "$backpass_state" == mise-npm ]]; then
  for entry in 'backpass:npm:backpass' 'acpx:npm:acpx'; do
    tool_label="${entry%%:*}"
    tool_decl="${entry#*:}"
    if grep -Fq "\"$tool_decl\"" "$conf_file" 2>/dev/null; then
      pass "$tool_label declared in $conf_file"
    else
      fail "$tool_label not declared in $conf_file despite backpass=mise-npm in $state_file"
    fi
  done
fi

section "Core agents"

check_mise_owned claude
check_mise_command_runs claude --version
check_mise_owned herdr

if [[ "$codex_state" == mise-npm ]]; then
  check_mise_owned codex
elif command -v codex >/dev/null 2>&1; then
  warning "codex is installed but the AI profile state says codex=$codex_state"
else
  pass "codex is not installed (optional subcomponent not selected)"
fi

section "Shared agent instructions (common/assets/AGENTS.md)"

check_symlink_owned "Claude Code (CLAUDE.md)" "$claude_md_target"
check_symlink_owned "Codex (AGENTS.md)" "$codex_agents_target"
check_symlink_owned "OpenCode (AGENTS.md)" "$opencode_agents_target"

section "GNHF (optional, unattended-run agent orchestrator)"

if [[ "$gnhf_state" == mise-npm ]]; then
  check_mise_owned gnhf
elif command -v gnhf >/dev/null 2>&1; then
  warning "gnhf is installed but the AI profile state says gnhf=$gnhf_state"
else
  pass "gnhf is not installed (optional subcomponent not selected)"
fi

section "FirstMate"

if [[ "$firstmate_state" == cloned ]]; then
  firstmate_dir="$XDG_DATA_HOME/firstmate"

  if [[ -d "$firstmate_dir/.git" ]]; then
    pass "FirstMate cloned: $firstmate_dir"
  else
    fail "FirstMate state says cloned, but $firstmate_dir/.git is missing"
  fi

  for command_name in gh tmux jq; do
    if command -v "$command_name" >/dev/null 2>&1; then
      pass "$command_name: $(command -v "$command_name")"
    else
      fail "$command_name not found (required by the FirstMate subcomponent)"
    fi
  done
else
  if [[ -d "$XDG_DATA_HOME/firstmate" ]]; then
    warning "FirstMate not selected (firstmate=$firstmate_state), but" \
      "$XDG_DATA_HOME/firstmate exists; remove it manually if unwanted"
  else
    pass "FirstMate is not installed (optional subcomponent not selected)"
  fi
fi

section "FirstMate toolchain (mise-managed)"

if [[ "$firstmate_state" == cloned ]]; then
  check_mise_owned gh-axi
  check_mise_owned chrome-devtools-axi
  check_mise_owned tasks-axi
  check_mise_owned quota-axi
else
  pass "FirstMate toolchain is not installed (FirstMate subcomponent not selected)"
fi

section "lavish-axi (rich-review UI; shared by FirstMate and backpass)"

if [[ "$lavish_axi_state" == mise-npm ]]; then
  check_mise_owned lavish-axi
else
  pass "lavish-axi is not installed (neither FirstMate nor backpass selected)"
fi

section "Treehouse (worktree isolation for FirstMate crewmates)"

if [[ "$treehouse_state" == installed ]]; then
  check_own_script_owned treehouse "$treehouse_target"
else
  if [[ -e "$treehouse_target" ]]; then
    warning "FirstMate/Treehouse not selected (treehouse=$treehouse_state)," \
      "but $treehouse_target exists; remove it manually if unwanted"
  else
    pass "Treehouse is not installed (FirstMate subcomponent not selected)"
  fi
fi

section "No Mistakes (local push validation gate)"

if [[ "$no_mistakes_state" == installed ]]; then
  check_own_script_owned no-mistakes "$no_mistakes_target"
else
  if [[ -e "$no_mistakes_target" ]]; then
    warning "FirstMate/No Mistakes not selected (no_mistakes=$no_mistakes_state)," \
      "but $no_mistakes_target exists; remove it manually if unwanted"
  else
    pass "No Mistakes is not installed (FirstMate subcomponent not selected)"
  fi
fi

section "backpass (optional, instructions-file tuning)"

if [[ "$backpass_state" == mise-npm ]]; then
  check_mise_owned backpass
  check_mise_owned acpx
elif command -v backpass >/dev/null 2>&1; then
  warning "backpass is installed but the AI profile state says backpass=$backpass_state"
else
  pass "backpass is not installed (optional subcomponent not selected)"
fi

finish_verification "AI profile verification"
