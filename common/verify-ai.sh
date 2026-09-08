#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

failures=0

state_file="$XDG_CONFIG_HOME/dotfiles/ai.conf"
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"
treehouse_target="$HOME/.local/bin/treehouse"

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

mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi

# check_mise_owned <command>: confirms the command resolves on PATH, and that
# it is the same binary mise reports managing -- catching the case where a
# second install (Homebrew, a global npm install, a native installer) shadows
# or duplicates the mise-owned copy this profile installed.
check_mise_owned() {
  local name="$1"
  local resolved mise_resolved

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

  if [[ "$resolved" == "$mise_resolved" ]] ||
    [[ -e "$resolved" && -e "$mise_resolved" && "$resolved" -ef "$mise_resolved" ]]; then
    pass "$name is mise-managed: $resolved"
  else
    fail "$name resolves outside mise, a possible duplicate install:" \
      "$resolved (mise manages $mise_resolved)"
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

section "Core agents"

check_mise_owned claude
check_mise_owned herdr

if [[ "$codex_state" == mise-npm ]]; then
  check_mise_owned codex
elif command -v codex >/dev/null 2>&1; then
  warning "codex is installed but the AI profile state says codex=$codex_state"
else
  pass "codex is not installed (optional subcomponent not selected)"
fi

section "FirstMate"

if [[ "$firstmate_state" == cloned ]]; then
  firstmate_dir="$XDG_DATA_HOME/firstmate"

  if [[ -d "$firstmate_dir/.git" ]]; then
    pass "FirstMate cloned: $firstmate_dir"
  else
    fail "FirstMate state says cloned, but $firstmate_dir/.git is missing"
  fi

  for command_name in gh tmux; do
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

section "Treehouse (worktree isolation for FirstMate crewmates)"

if [[ "$treehouse_state" == installed ]]; then
  if [[ -x "$treehouse_target" ]]; then
    pass "treehouse: $treehouse_target"
  else
    fail "AI profile state says treehouse=installed, but $treehouse_target is" \
      "missing or not executable"
  fi

  # Treehouse has no mise registry entry, so it is not checked against mise
  # ownership like Claude Code/Codex/Herdr above; only that it resolves and
  # that nothing else on PATH shadows the copy this installer placed.
  resolved_treehouse="$(command -v treehouse 2>/dev/null || true)"
  if [[ -n "$resolved_treehouse" ]] &&
    { [[ "$resolved_treehouse" == "$treehouse_target" ]] ||
      [[ "$resolved_treehouse" -ef "$treehouse_target" ]]; }; then
    pass "treehouse on PATH resolves to the installed copy"
  elif [[ -n "$resolved_treehouse" ]]; then
    fail "treehouse on PATH ($resolved_treehouse) is not $treehouse_target," \
      "a possible duplicate install"
  else
    warning "$treehouse_target is not on PATH"
  fi
else
  if [[ -e "$treehouse_target" ]]; then
    warning "FirstMate/Treehouse not selected (treehouse=$treehouse_state)," \
      "but $treehouse_target exists; remove it manually if unwanted"
  else
    pass "Treehouse is not installed (FirstMate subcomponent not selected)"
  fi
fi

printf '\n'
if ((failures > 0)); then
  printf '\033[1;31mAI profile verification failed:\033[0m %d failure(s)\n' \
    "$failures"
  exit 1
fi

printf '\033[1;32mAI profile verification passed.\033[0m\n'
