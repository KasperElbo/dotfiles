#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

failures=0

state_file="$XDG_CONFIG_HOME/dotfiles/ai.conf"
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"
treehouse_target="$HOME/.local/bin/treehouse"
no_mistakes_target="$HOME/.local/bin/no-mistakes"
agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_md_target="$HOME/.claude/CLAUDE.md"
codex_agents_target="$codex_home/AGENTS.md"
opencode_agents_target="$XDG_CONFIG_HOME/opencode/AGENTS.md"

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

[[ -f "$state_file" ]] || {
  printf 'AI profile state is missing: %s\n' "$state_file" >&2
  exit 1
}

codex_state="$(awk -F= '$1 == "codex" { print $2 }' "$state_file")"
firstmate_state="$(awk -F= '$1 == "firstmate" { print $2 }' "$state_file")"
treehouse_state="$(awk -F= '$1 == "treehouse" { print $2 }' "$state_file")"
no_mistakes_state="$(awk -F= '$1 == "no_mistakes" { print $2 }' "$state_file")"
lavish_axi_state="$(awk -F= '$1 == "lavish_axi" { print $2 }' "$state_file")"
gnhf_state="$(awk -F= '$1 == "gnhf" { print $2 }' "$state_file")"
backpass_state="$(awk -F= '$1 == "backpass" { print $2 }' "$state_file")"

caller_path="$PATH"
mise_command="$(resolve_mise_command || true)"
mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
mise_shims_dir="${MISE_SHIMS_DIR:-$mise_data_dir/shims}"

# Verification has the same deterministic command environment as installation,
# even when called from a shell that predates the final Zsh configuration.
establish_user_tool_environment

# check_mise_owned <command>: confirms the command resolves on PATH, and that
# it is either mise's shim or the executable mise reports managing. This
# catches a second install (Homebrew, global npm, native installer) shadowing
# the mise-owned copy while supporting mise's normal shim-based PATH setup.
check_mise_owned() {
  local name="$1"
  local resolved mise_resolved mise_shim caller_resolved

  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    fail "$name not found"
    return
  fi

  if [[ -z "$mise_command" ]]; then
    warning "mise not found; cannot confirm $name ($resolved) is mise-owned"
    return
  fi

  mise_resolved="$("$mise_command" which "$name" 2>/dev/null || true)"
  if [[ -z "$mise_resolved" ]]; then
    warning "$name is on PATH ($resolved) but mise does not report managing it"
    return
  fi

  if [[ ! -x "$mise_resolved" ]]; then
    fail "$name's mise-managed executable is missing or not executable: $mise_resolved"
    return
  fi

  mise_shim="$mise_shims_dir/$name"
  caller_resolved="$(PATH="$caller_path" command -v "$name" 2>/dev/null || true)"
  if [[ ":$caller_path:" == *":$mise_shims_dir:"* &&
    -n "$caller_resolved" ]] &&
    ! shell_paths_match "$caller_resolved" "$mise_resolved" &&
    ! shell_paths_match "$caller_resolved" "$mise_shim"; then
    fail "$name resolves outside mise, a possible duplicate install:" \
      "$caller_resolved (mise manages $mise_resolved)"
    return
  fi

  if shell_paths_match "$resolved" "$mise_resolved"; then
    pass "$name is mise-managed: $resolved"
  elif shell_paths_match "$resolved" "$mise_shim"; then
    pass "$name is mise-managed via shim: $resolved -> $mise_resolved"
  else
    fail "$name resolves outside mise, a possible duplicate install:" \
      "$resolved (mise manages $mise_resolved)"
  fi
}

# check_command_runs <command> <arguments...>: catches an executable that was
# installed but is unusable, such as Claude Code without its required npm
# postinstall step linking the platform-native binary.
check_command_runs() {
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

# check_symlink_owned <label> <target>: confirms <target> is a symlink
# resolving to the shared common/assets/AGENTS.md this profile links, rather
# than missing, a plain file, or a symlink some other tool/config pointed
# elsewhere -- either of which means this profile did not link it (by
# design: an existing file or symlink there always takes precedence).
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

  if [[ "$(resolve_symlink_target "$target" 2>/dev/null || true)" == "$agents_source" ]]; then
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
check_command_runs claude --version
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

printf '\n'
if ((failures > 0)); then
  printf '\033[1;31mAI profile verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

printf '\033[1;32mAI profile verification passed.\033[0m\n'
