#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/verify.sh"
# shellcheck source=lib/fetch.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fetch.sh"
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
requested_state="$(profile_state_read "$state_file" requested ai 2>/dev/null || printf 'not-recorded')"
firstmate_source_state="$(profile_state_read "$state_file" firstmate_source ai 2>/dev/null || printf 'not-recorded')"
firstmate_commit_state="$(profile_state_read "$state_file" firstmate_commit ai 2>/dev/null || printf 'not-recorded')"
treehouse_target_digest_state="$(profile_state_read "$state_file" treehouse_target_digest ai 2>/dev/null || printf 'not-recorded')"
no_mistakes_target_digest_state="$(profile_state_read "$state_file" no_mistakes_target_digest ai 2>/dev/null || printf 'not-recorded')"
treehouse_target_path_state="$(profile_state_read "$state_file" treehouse_target_path ai 2>/dev/null || printf 'not-recorded')"
no_mistakes_target_path_state="$(profile_state_read "$state_file" no_mistakes_target_path ai 2>/dev/null || printf 'not-recorded')"

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
    run_mise "$mise_command" exec -- "$name" "$@" >/dev/null 2>&1; then
    pass "$name launches successfully: $name $*"
  else
    fail "$name is installed but '$name $*' failed"
  fi
}

# check_own_script_owned <command> <target> <recorded-path>: for a tool with no
# mise registry entry, confirms <target> exists and is executable, that it
# still resolves to the file the installer recorded -- an upstream is free to
# install its binary elsewhere and leave a launcher symlink on PATH -- and that
# nothing else on PATH shadows it with a duplicate install.
check_own_script_owned() {
  local name="$1"
  local target="$2"
  local recorded_path="${3:-not-recorded}"
  local resolved installed

  if [[ -x "$target" ]]; then
    installed="$(verify_canonical_existing_path "$target" 2>/dev/null || true)"
    if [[ -z "$installed" ]]; then
      fail "$name does not resolve to an existing file: $target"
      return
    fi
    if [[ "$installed" == "$target" ]]; then
      pass "$name: $target"
    else
      pass "$name: $target -> $installed"
    fi
  else
    fail "$name is missing or not executable: $target"
    return
  fi

  if [[ -L "$target" ]]; then
    if [[ "$recorded_path" == not-recorded ]]; then
      warning "$name is a launcher symlink with no recorded installed path;" \
        "rerun the AI installer so removal can prove ownership of the binary"
    elif [[ "$recorded_path" != "$installed" ]]; then
      warning "$name now resolves to $installed, not the recorded $recorded_path;" \
        "removal will refuse to delete it"
    else
      pass "$name resolves to the recorded installed binary: $recorded_path"
    fi
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

# Under additive semantics a component that is present but not selected is
# never rewritten or silently deleted. It is reported, with the one command
# that would remove it, so state and filesystem never disagree in silence.
report_disabled_but_present() {
  local label="$1"
  local path="$2"
  local flag="$3"

  if [[ -e "$path" || -L "$path" ]]; then
    warning "$label is not selected but $path is still present;" \
      "run './common/install-ai.sh $flag' to remove it"
  else
    pass "$label is not installed (optional subcomponent not selected)"
  fi
}

# check_recorded_digest <label> <path> <recorded>: compares the installed
# binary against the digest recorded for that binary -- not against the digest
# of the remote installer that produced it, which is a different artifact. A
# component whose file no longer matches is still usable,
# but this repository can no longer prove it owns it -- and a later removal
# will refuse to delete it. Say so rather than letting it look verified.
check_recorded_digest() {
  local label="$1"
  local path="$2"
  local recorded="$3"
  local actual

  if [[ "$recorded" == not-recorded || -z "$recorded" ]]; then
    warning "$label has no recorded installer digest; rerun the AI installer so removal can prove ownership"
    return
  fi

  actual="$(fetch_sha256 "$path" 2>/dev/null || true)"
  if [[ "$actual" == "$recorded" ]]; then
    pass "$label matches its recorded provenance digest"
  else
    warning "$label ($path) no longer matches the recorded digest; it was replaced or updated outside this installer, and removal will refuse to delete it"
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

pass "Requested optional components: $requested_state"

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

# mise installs and updates Claude Code; Claude Code must not replace its own
# package. Without this the tool reinstalls itself under the mise-managed Node
# prefix and shadows the dedicated npm-backend installation.
check_login_environment DISABLE_UPDATES 1

check_no_global_npm_duplicate @anthropic-ai/claude-code @openai/codex gnhf \
  backpass acpx gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi

if [[ "$codex_state" == mise-npm ]]; then
  check_mise_owned codex
elif command -v codex >/dev/null 2>&1; then
  warning "codex is not selected (codex=$codex_state) but is still on PATH;" \
    "run './common/install-ai.sh --no-codex' to remove it"
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
  warning "gnhf is not selected (gnhf=$gnhf_state) but is still on PATH;" \
    "run './common/install-ai.sh --no-gnhf' to remove it"
else
  pass "gnhf is not installed (optional subcomponent not selected)"
fi

section "FirstMate"

if [[ "$firstmate_state" == cloned ]]; then
  firstmate_dir="$XDG_DATA_HOME/firstmate"

  if [[ -d "$firstmate_dir/.git" ]]; then
    pass "FirstMate cloned: $firstmate_dir"
    firstmate_origin="$(git -C "$firstmate_dir" config --get remote.origin.url 2>/dev/null || true)"
    firstmate_head="$(git -C "$firstmate_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$firstmate_source_state" == not-recorded ]]; then
      warning "FirstMate has no recorded source; rerun the AI installer so removal can prove ownership"
    elif [[ "$firstmate_origin" != "$firstmate_source_state" ]]; then
      warning "FirstMate origin (${firstmate_origin:-none}) is not the recorded $firstmate_source_state; removal will refuse to delete it"
    else
      pass "FirstMate origin matches the recorded source: $firstmate_source_state"
    fi
    if [[ "$firstmate_commit_state" == not-recorded ]]; then
      warning "FirstMate has no recorded commit; rerun the AI installer so removal can prove ownership"
    elif [[ "$firstmate_head" != "$firstmate_commit_state" ]]; then
      warning "FirstMate is at ${firstmate_head:-an unreadable commit}, not the recorded $firstmate_commit_state; it moved outside this installer"
    else
      pass "FirstMate is at the recorded rolling commit $firstmate_commit_state"
    fi
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
  report_disabled_but_present FirstMate "$XDG_DATA_HOME/firstmate" --no-firstmate
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
  check_own_script_owned treehouse "$treehouse_target" "$treehouse_target_path_state"
  check_recorded_digest Treehouse "$treehouse_target" "$treehouse_target_digest_state"
else
  report_disabled_but_present Treehouse "$treehouse_target" --no-firstmate
fi

section "No Mistakes (local push validation gate)"

if [[ "$no_mistakes_state" == installed ]]; then
  check_own_script_owned no-mistakes "$no_mistakes_target" "$no_mistakes_target_path_state"
  check_recorded_digest "No Mistakes" "$no_mistakes_target" "$no_mistakes_target_digest_state"
else
  report_disabled_but_present "No Mistakes" "$no_mistakes_target" --no-firstmate
fi

section "backpass (optional, instructions-file tuning)"

if [[ "$backpass_state" == mise-npm ]]; then
  check_mise_owned backpass
  check_mise_owned acpx
elif command -v backpass >/dev/null 2>&1; then
  warning "backpass is not selected (backpass=$backpass_state) but is still on PATH;" \
    "run './common/install-ai.sh --no-backpass' to remove it"
else
  pass "backpass is not installed (optional subcomponent not selected)"
fi

finish_verification "AI profile verification"
