#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"
# shellcheck source=../../../common/lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/tool-floors.sh"

verify_reset
run_dev_workflows="false"
verify_latex="false"

while (($#)); do
  case "$1" in
  --dev-workflows)
    run_dev_workflows="true"
    ;;
  --smoke-test)
    # Deprecated spelling of --dev-workflows, kept because it is documented in
    # released instructions. It resolves to identical behavior.
    printf 'WARNING: --smoke-test is deprecated; use --dev-workflows instead.\n' >&2
    run_dev_workflows="true"
    ;;
  --latex)
    verify_latex="true"
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
  shift
done

# windows_interop_resolution <path>: the Windows executable <path> ultimately
# names, whether it is one itself or a symlink chain ending at one. Prints
# nothing for an empty path or one that stays on the Linux side.
#
# command -v answers with the first PATH hop and does not follow symlinks, so
# asking is_windows_path about that spelling alone accepted a Linux-spelled
# shim pointing at bat.exe and then ran it through WSL interop (issue #396,
# GAP-11). The repository already guards this by hand elsewhere:
# resolve_mise_command prefers $HOME/.local/bin/mise over PATH exactly so a
# stale WSL process cannot select mise.exe.
#
# Scope, stated rather than implied: this closes the symlink case. A wrapper
# script that execs a .exe is still a Linux-native file by every test here and
# needs its own treatment.
windows_interop_resolution() {
  local path="$1"
  local resolved=""

  [[ -n "$path" ]] || return 0
  if is_windows_path "$path"; then
    printf '%s\n' "$path"
    return 0
  fi

  # resolve_existing_path follows the whole chain; resolve_symlink_target is
  # the fallback for a link whose Windows target is not mounted right now,
  # which still names a target worth refusing.
  resolved="$(resolve_existing_path "$path" 2>/dev/null || true)"
  [[ -n "$resolved" ]] ||
    resolved="$(resolve_symlink_target "$path" 2>/dev/null || true)"

  [[ -n "$resolved" ]] || return 0
  ! is_windows_path "$resolved" || printf '%s\n' "$resolved"
}

# check_linux_command <name> [--probe [arguments]]: check_command, after first
# refusing a command that resolves to a Windows executable.
check_linux_command() {
  local command_name="$1"
  local command_path
  local windows_target

  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  windows_target="$(windows_interop_resolution "$command_path")"
  if [[ -n "$windows_target" ]]; then
    fail "$command_name resolves to a Windows executable: $windows_target"
  else
    check_command "$@"
  fi
}

check_windows_path_command_absent() {
  local command_name="$1"
  local command_path

  command_path="$(PATH="$system_path" command -v "$command_name" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    pass "$command_name is not inherited through PATH"
  else
    fail "$command_name resolves through inherited Windows PATH: $command_path"
  fi
}

if ! require_fedora_wsl; then
  exit 1
fi

section "WSL runtime"

if systemd_is_running; then
  pass "systemd is PID 1"
else
  warning "systemd is not PID 1; it is optional for this profile but required by some later service profiles"
fi

if [[ "$PWD" == /mnt/[a-zA-Z]/* ]]; then
  warning "Repository is under a Windows-mounted drive; use the WSL Linux filesystem for normal development"
else
  pass "Current repository is on the Linux filesystem"
fi

current_user="$(id -un)"
login_shell="$(login_shell_for_user "$current_user" 2>/dev/null || true)"
zsh_path="$(resolve_zsh_path 2>/dev/null || true)"
if shell_paths_match "$login_shell" "$zsh_path"; then
  pass "Zsh is the default login shell"
else
  fail "Default login shell is not Zsh: ${login_shell:-unknown}"
fi

section "Windows PATH injection policy"

# This is the check that decides whether Windows directories reach PATH at all.
# appendWindowsPath=false is a WSL-level setting: it governs every context on
# the machine -- systemd units, "wsl.exe -e", VS Code's integrated shell, cron,
# any script -- whereas the Zsh hook in platform-env.zsh only ever runs in an
# interactive Zsh login shell. A machine where configure-interop.sh wrote the
# file but nobody ran "wsl --shutdown" still injects the Windows PATH into all
# of those, and only reading the file can see it.
#
# The value is read, not the file's formatting compared: a wsl.conf this
# repository did not write may spell the key "appendWindowsPath = false", and
# WSL reads that as false, so reporting it as unset would fail a machine that
# is correctly configured. ini_section_key_value shares its key-line shape with
# the renderer configure-interop.sh writes with.
wsl_conf_file="${WSL_CONF_FILE:-/etc/wsl.conf}"
wsl_conf_remedy="run platforms/fedora-wsl/scripts/configure-interop.sh, then 'wsl --shutdown' from Windows PowerShell (this affects every WSL distribution, not just this one) and reopen this distribution"

if [[ -r "$wsl_conf_file" ]]; then
  wsl_conf_content="$(cat "$wsl_conf_file")"
  append_windows_path="$(
    ini_section_key_value "$wsl_conf_content" "interop" "appendWindowsPath"
  )"
  case "$append_windows_path" in
  false)
    pass "$wsl_conf_file sets [interop] appendWindowsPath=false, so no context inherits the Windows PATH"
    ;;
  "")
    fail "$wsl_conf_file does not set [interop] appendWindowsPath=false, so every non-interactive context (systemd units, 'wsl.exe -e', VS Code, cron) still inherits the Windows PATH: $wsl_conf_remedy"
    ;;
  *)
    fail "$wsl_conf_file sets [interop] appendWindowsPath=$append_windows_path, so every non-interactive context (systemd units, 'wsl.exe -e', VS Code, cron) still inherits the Windows PATH: $wsl_conf_remedy"
    ;;
  esac
else
  fail "Cannot read $wsl_conf_file, so [interop] appendWindowsPath=false is unverified: $wsl_conf_remedy"
fi

section "Inherited Windows PATH isolation"

# What the system actually hands a process, before any configuration in this
# repository acts on it. "zsh -f" reads no user rc files, so platform-env.zsh's
# stripper does not run and cannot mask an entry that is really there. This is
# the PATH sample that can fail; the sanitized one below cannot, by
# construction.
#
# It is still sampled from this process's own environment, so it reports what
# reached the verifier. The /etc/wsl.conf assertion above, not this, is what
# proves the contexts the verifier cannot start from are clean.
system_path="$(
  zsh -fc \
    'printf "\n__DOTFILES_VERIFY_SYSTEM_PATH__%s\n" "$PATH"' 2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_SYSTEM_PATH__//p' |
    tail -n 1
)"
if [[ -z "$system_path" ]]; then
  fail "Could not inspect the unsanitized system PATH"
else
  system_path_has_windows_entry="false"
  IFS=: read -r -a system_path_entries <<<"$system_path"
  for path_entry in "${system_path_entries[@]}"; do
    if is_windows_path "$path_entry"; then
      fail "The unsanitized system PATH contains a Windows entry: $path_entry ($wsl_conf_remedy)"
      system_path_has_windows_entry="true"
    fi
  done

  if [[ "$system_path_has_windows_entry" == "false" ]]; then
    pass "The unsanitized system PATH contains only Linux filesystem entries"
  fi
fi

# Without a system PATH these lookups would run against an empty PATH and
# report vacuous passes. The probe failure is already recorded above.
if [[ -n "$system_path" ]]; then
  for command_name in node.exe dotnet.exe python.exe claude.exe codex.exe; do
    check_windows_path_command_absent "$command_name"
  done
  pass "Explicit .exe lookup was checked in the unsanitized system PATH"
else
  warn "Skipping explicit .exe lookup: the unsanitized system PATH could not be inspected"
fi

section "Linux-native commands"

login_path="$(
  verify_login_zsh -lic \
    'printf "\n__DOTFILES_VERIFY_PATH__%s\n" "$PATH"' 2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_PATH__//p' |
    tail -n 1
)"
if [[ -z "$login_path" ]]; then
  fail "Could not inspect the Zsh login PATH"
else
  # This sample has already been through platform-env.zsh's stripper, so a
  # Windows entry here means that stripper is broken -- it is not, and cannot
  # be, evidence that WSL stopped injecting one. Interop policy is proved
  # above.
  path_has_windows_entry="false"
  IFS=: read -r -a login_path_entries <<<"$login_path"
  for path_entry in "${login_path_entries[@]}"; do
    if is_windows_path "$path_entry"; then
      fail "The Zsh PATH sanitizer left a Windows entry in the login PATH: $path_entry"
      path_has_windows_entry="true"
    fi
  done

  if [[ "$path_has_windows_entry" == "false" ]]; then
    pass "The Zsh PATH sanitizer leaves only Linux filesystem entries in the login PATH (proof that the Zsh layer works, not that Windows PATH injection is off)"
  fi
fi

selected_theme="macchiato"
theme_state="$XDG_CONFIG_HOME/dotfiles/theme"
if [[ -r "$theme_state" ]]; then
  selected_theme="$(<"$theme_state")"
fi
expected_starship_config="$XDG_CONFIG_HOME/starship/catppuccin-${selected_theme}.toml"
starship_config="$(
  verify_login_zsh -lic \
    'printf "\n__DOTFILES_VERIFY_STARSHIP__%s\n" "${STARSHIP_CONFIG:-}"' \
    2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_STARSHIP__//p' |
    tail -n 1
)"
if [[ "$starship_config" != "$expected_starship_config" ]]; then
  fail "Zsh STARSHIP_CONFIG is not the selected theme: ${starship_config:-unset}"
elif [[ ! -r "$starship_config" ]]; then
  fail "Selected Starship configuration is not readable: $starship_config"
else
  pass "Zsh loads the selected Starship configuration: $starship_config"
fi

mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi

# The PATH this verifier was started with, before it adds mise's shims to its
# own process: check_mise_owned asks a fresh login from it, and a login
# inherits PATH, so shims recorded here would sit ahead of the dnf copy that
# check looks for.
verify_caller_path="$PATH"
if [[ -n "$mise_command" ]]; then
  establish_user_tool_environment
else
  fail "mise not found"
fi

# System commands come from dnf, an upstream installer or this repository.
# Each is run as well as found, because a resolved path is not a working
# command.
commands=(
  bat
  delta
  eza
  fd
  fzf
  gh
  git
  mise
  nvim
  rg
  shellcheck
  sqlite3
  starship
  stow
  tmux
  zoxide
  zsh
)

for command_name in "${commands[@]}"; do
  check_linux_command "$command_name" --probe
done

# The interop helpers are this repository's own scripts, and running one
# would reach Windows, so they are checked for resolution only.
for command_name in wsl-copy wsl-open wsl-paste; do
  check_linux_command "$command_name"
done

# mise owns these runtimes, so being Linux-native is not enough: a dnf package
# of the same name earlier on PATH is exactly the second copy check_mise_owned
# exists to catch. It resolves them in the PATH the fresh Zsh login above
# reported, which is what a new terminal will use.
VERIFY_CONFIGURED_LOGIN_PATH="$login_path"
VERIFY_CALLER_PATH="$verify_caller_path"
VERIFY_MISE_COMMAND="$mise_command"
mise_tools=(
  ast-grep
  dotnet
  dotnet-easydotnet
  lazygit
  neovim-node-host
  node
  npm
  npx
  python
  tree-sitter
  uv
)

check_mise_context

for command_name in "${mise_tools[@]}"; do
  check_mise_owned "$command_name"
done

if [[ "$verify_latex" == "true" ]]; then
  section "LaTeX toolchain"
  for command_name in biber latex latexindent latexmk lualatex pdflatex xelatex; do
    check_linux_command "$command_name"
  done
fi

ai_state="$(verify_optional_capability_state fedora-wsl ai || true)"
ai_disposition="$(verify_optional_capability_disposition fedora-wsl ai || true)"

section "AI-assisted development profile"

case "$ai_disposition" in
verify | leftover)
  verify_optional_capability_report "AI profile" "$ai_state" "$ai_disposition"

  if "$DOTFILES_ROOT/common/verify-ai.sh"; then
    pass "AI profile verification completed"
  else
    fail "AI profile verification failed"
  fi

  ai_login_commands=(claude herdr)
  while IFS='=' read -r component ownership; do
    case "$component:$ownership" in
    codex:mise-npm) ai_login_commands+=(codex) ;;
    gnhf:mise-npm) ai_login_commands+=(gnhf) ;;
    gh_axi:mise-npm) ai_login_commands+=(gh-axi) ;;
    chrome_devtools_axi:mise-npm) ai_login_commands+=(chrome-devtools-axi) ;;
    lavish_axi:mise-npm) ai_login_commands+=(lavish-axi) ;;
    tasks_axi:mise-npm) ai_login_commands+=(tasks-axi) ;;
    quota_axi:mise-npm) ai_login_commands+=(quota-axi) ;;
    backpass:mise-npm) ai_login_commands+=(backpass) ;;
    acpx:mise-npm) ai_login_commands+=(acpx) ;;
    treehouse:installed) ai_login_commands+=(treehouse) ;;
    no_mistakes:installed) ai_login_commands+=(no-mistakes) ;;
    esac
  done <"$ai_state"

  for command_name in "${ai_login_commands[@]}"; do
    if verify_login_zsh -lic 'command -v "$1" >/dev/null' _ "$command_name" \
      >/dev/null 2>&1; then
      pass "Fresh Zsh login resolves $command_name"
    else
      fail "Fresh Zsh login does not resolve $command_name"
    fi
  done

  if verify_login_zsh -lic 'claude --version >/dev/null' >/dev/null 2>&1; then
    pass "Claude Code starts in a fresh Zsh login"
  else
    fail "Claude Code does not start in a fresh Zsh login"
  fi

  # "is Linux-native" is a claim about where the command ends up, so it is
  # made about the resolved target rather than the first PATH hop (GAP-11).
  for command_name in claude codex herdr treehouse; do
    command_path="$(command -v "$command_name" 2>/dev/null || true)"
    if [[ -z "$command_path" ]]; then
      continue
    fi
    windows_target="$(windows_interop_resolution "$command_path")"
    if [[ -n "$windows_target" ]]; then
      fail "$command_name resolves to a Windows executable: $windows_target"
    else
      pass "$command_name is Linux-native: $command_path"
    fi
  done
  ;;
missing | corrupt)
  verify_optional_capability_report "AI profile" "$ai_state" "$ai_disposition"
  ;;
*)
  # Not selected, and no state file. The profile owns files outside its own
  # state, so an unselected machine is still asked whether any of them remain.
  agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  # resolved_link_matches, not a string comparison of the two spellings:
  # resolve_symlink_target canonicalizes physically while $agents_source is
  # built from DOTFILES_ROOT, which common.sh builds with a logical cd/pwd and
  # so keeps the symlinks this invocation walked through. Under any symlinked
  # checkout the two spellings differ although they name the same file, and
  # all three symlink probes below silently stopped firing. The installer
  # already uses the safe helper for this same comparison (issue #398, GAP-08).
  is_agents_symlink() {
    [[ -L "$1" ]] && resolved_link_matches "$1" "$agents_source"
  }

  if [[ -f "$XDG_CONFIG_HOME/mise/conf.d/ai.toml" ||
    -e "$HOME/.local/bin/treehouse" ||
    -d "$XDG_DATA_HOME/firstmate" ]] ||
    is_agents_symlink "$HOME/.claude/CLAUDE.md" ||
    is_agents_symlink "$codex_home/AGENTS.md" ||
    is_agents_symlink "$XDG_CONFIG_HOME/opencode/AGENTS.md"; then
    fail "AI profile is not selected, but AI-owned files remain (run" \
      "common/install-ai.sh, or remove them by hand)"
  else
    pass "AI profile is not installed (not selected)"
  fi
  ;;
esac

section "Windows executable interop"

interop_probe="$(windows_interop_probe_path)"
binfmt_hint="$(windows_interop_binfmt_hint)"

if windows_interop_works; then
  pass "explicit Windows executable interop works ($interop_probe; binfmt_misc: $binfmt_hint)"
else
  fail "$(
    cat <<EOF
explicit Windows executable interop is not working: running
$interop_probe /c echo interop-ok did not produce "interop-ok"
(binfmt_misc: $binfmt_hint). Expected /etc/wsl.conf to contain:

  [interop]
  enabled=true
  appendWindowsPath=false

then a restart: run 'wsl --shutdown' from Windows PowerShell (this affects
every WSL distribution, not just this one), then reopen this distribution.
platforms/fedora-wsl/scripts/configure-interop.sh sets this for you.
EOF
  )"
fi

section "Representative runtimes"

if dotnet --version >/dev/null 2>&1; then
  pass ".NET SDK starts"
else
  fail ".NET SDK failed"
fi

case "$(uname -m)" in
aarch64 | arm64) check_easy_dotnet_debugger linux-arm64 ;;
x86_64 | amd64) check_easy_dotnet_debugger linux-x64 ;;
*) fail "Unsupported .NET debugger architecture: $(uname -m)" ;;
esac

if node --version >/dev/null 2>&1; then
  pass "Node starts"
else
  fail "Node failed"
fi

if npm --version >/dev/null 2>&1; then
  pass "npm starts"
else
  fail "npm failed"
fi

if npx --version >/dev/null 2>&1; then
  pass "npx is available for project-local Angular/TypeScript tools"
else
  fail "npx failed"
fi

if python --version >/dev/null 2>&1; then
  pass "Python starts"
else
  fail "Python failed"
fi

if uv --version >/dev/null 2>&1; then
  pass "uv starts"
else
  fail "uv failed"
fi

section "Neovim tooling"

check_version_at_least "Neovim" "$(tool_version nvim)" "$(tool_floor nvim)"
check_mason_inventory "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"

# Until this, "Neovim tooling passed" meant something different here than on
# Fedora: the version and the Mason inventory, and nothing about the plugins or
# about whether the configuration loads at all. Both questions are asked the
# same way on every platform now, the plugin tree from the deployed lock file
# first because a start would otherwise fill in what it found missing (#371).
check_lazy_plugin_state "$XDG_CONFIG_HOME/nvim/lazy-lock.json"
check_markdown_preview_server "$XDG_CONFIG_HOME/nvim/lazy-lock.json"
check_neovim_starts Neovim "$(tool_floor nvim)"

section "Catppuccin tmux"

check_catppuccin_tmux

section "Configuration links"

check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh/" \
  "$DOTFILES_ROOT/zsh/.zshenv"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh/" \
  "$DOTFILES_ROOT/zsh/.config/zsh/.zshrc"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform-env.zsh"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform.zsh"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git/" \
  "$DOTFILES_ROOT/git/.config/git/config"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" "$DOTFILES_ROOT/mise/" \
  "$DOTFILES_ROOT/mise/.config/mise/config.toml"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim/" \
  "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/init.lua"
check_symlink "$XDG_CONFIG_HOME/nvim/lua/plugins/wsl.lua" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/nvim-wsl/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua"
check_symlink "$HOME/.local/bin/wsl-copy" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/.local/bin/wsl-copy"
check_symlink "$HOME/.local/bin/wsl-paste" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/.local/bin/wsl-paste"
check_symlink "$HOME/.local/bin/wsl-open" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/.local/bin/wsl-open"

if [[ -e "$XDG_CONFIG_HOME/ghostty/config" ]]; then
  warning "Ghostty configuration exists in WSL but is not managed by this profile"
else
  pass "Windows owns the terminal; no Ghostty config was deployed in WSL"
fi

ocaml_state="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"
# Unconditional: the shared verifier reports an unselected profile as not
# applicable, and only it can tell that apart from a selected but broken one.
section "OCaml profile"
# What the sub-verifier established, not one of the three worlds it exits 0
# for. common/verify-ocaml.sh answers the same way for a selected and healthy
# profile, a selected one it cannot observe, and one that is neither selected
# nor installed -- and ocaml is disabled for fedora-wsl, so a stock machine
# with no opam and no ocamlc was printing a green line claiming the compiler
# starts (issue #396, GAP-07). The sub-verifier prints which world it found;
# this line only reports that it ran and was satisfied. Fedora's twin already
# words it neutrally.
if DOTFILES_NATIVE_PREFIX=/usr \
  DOTFILES_NATIVE_OWNER=opam \
  DOTFILES_NATIVE_OWNER_QUERY='rpm -qf --queryformat %{NAME}' \
  "$DOTFILES_ROOT/common/verify-ocaml.sh"; then
  pass "OCaml profile verification completed"
else
  fail "OCaml profile verification failed"
fi

verify_optional_capability "Containers (Podman)" fedora-wsl containers \
  "$DOTFILES_ROOT/platforms/fedora-wsl/scripts/verify-containers.sh" \
  --skip-smoke-test

if [[ "$run_dev_workflows" == "true" ]]; then
  section "Development workflow smoke tests"
  if "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --all; then
    pass ".NET, Angular/TypeScript, Python and JSON workflows"
  else
    fail "One or more development workflow smoke tests failed"
  fi

  if [[ -f "$ocaml_state" ]]; then
    if "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --ocaml; then
      pass "OCaml workflow"
    else
      fail "OCaml development workflow smoke test failed"
    fi
  fi

  if [[ "$verify_latex" == "true" ]]; then
    if "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --latex; then
      pass "LaTeX formatting, multi-file build, Biber, PDF and error workflow"
    else
      fail "LaTeX development workflow smoke test failed"
    fi
  fi
fi

finish_verification "Fedora WSL verification"
