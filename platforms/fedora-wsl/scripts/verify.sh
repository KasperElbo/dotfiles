#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"

failures=0
warnings=0
run_smoke_tests="false"

if [[ "${1:-}" == "--smoke-test" ]]; then
  run_smoke_tests="true"
  shift
fi
[[ $# -eq 0 ]] || die "Unknown option: $1"

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

check_linux_command() {
  local command_name="$1"
  local command_path

  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  if [[ -z "$command_path" ]]; then
    fail "$command_name not found"
  elif is_windows_path "$command_path"; then
    fail "$command_name resolves to a Windows executable: $command_path"
  else
    pass "$command_name: $command_path"
  fi
}

check_symlink() {
  local target="$1"
  local expected_prefix="$2"
  local resolved

  if [[ ! -L "$target" ]]; then
    fail "$target is not a symlink"
    return
  fi

  resolved="$(readlink -f "$target")"
  if [[ "$resolved" == "$expected_prefix"* ]]; then
    pass "$target -> $resolved"
  else
    fail "$target resolves outside dotfiles repo: $resolved"
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

section "Linux-native commands"

login_path="$(
  zsh -lic \
    'printf "\n__DOTFILES_VERIFY_PATH__%s\n" "$PATH"' 2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_PATH__//p' |
    tail -n 1
)"
if [[ -z "$login_path" ]]; then
  fail "Could not inspect the Zsh login PATH"
else
  path_has_windows_entry="false"
  IFS=: read -r -a login_path_entries <<<"$login_path"
  for path_entry in "${login_path_entries[@]}"; do
    if is_windows_path "$path_entry"; then
      fail "Zsh PATH still contains a Windows entry: $path_entry"
      path_has_windows_entry="true"
    fi
  done

  if [[ "$path_has_windows_entry" == "false" ]]; then
    pass "Zsh PATH contains only Linux filesystem entries"
  fi
fi

selected_theme="macchiato"
theme_state="$XDG_CONFIG_HOME/dotfiles/theme"
if [[ -r "$theme_state" ]]; then
  selected_theme="$(<"$theme_state")"
fi
expected_starship_config="$XDG_CONFIG_HOME/starship/catppuccin-${selected_theme}.toml"
starship_config="$(
  zsh -lic \
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

if [[ -n "$mise_command" ]]; then
  # Make the managed tools visible in this non-interactive verification shell.
  eval "$("$mise_command" activate bash)"
else
  fail "mise not found"
fi

commands=(
  ast-grep
  bat
  delta
  dotnet
  dotnet-easydotnet
  eza
  fd
  fzf
  gh
  git
  lazygit
  mise
  neovim-node-host
  node
  npm
  npx
  nvim
  python
  rg
  shellcheck
  sqlite3
  starship
  stow
  tmux
  tree-sitter
  uv
  wsl-copy
  wsl-open
  wsl-paste
  zoxide
  zsh
)

for command_name in "${commands[@]}"; do
  check_linux_command "$command_name"
done

if command -v codex >/dev/null 2>&1; then
  codex_path="$(command -v codex)"
  if is_windows_path "$codex_path"; then
    fail "codex resolves to Windows: $codex_path"
  else
    pass "optional codex is Linux-native: $codex_path"
  fi
else
  pass "optional codex is not installed by the WSL profile"
fi

section "Representative runtimes"

if dotnet --version >/dev/null 2>&1; then
  pass ".NET SDK starts"
else
  fail ".NET SDK failed"
fi

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

section "Configuration links"

check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh/"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh/"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/zsh-platform/"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git/"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" "$DOTFILES_ROOT/mise/"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim/"
check_symlink "$XDG_CONFIG_HOME/nvim/lua/plugins/wsl.lua" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/nvim-wsl/"
check_symlink "$HOME/.local/bin/wsl-copy" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/"
check_symlink "$HOME/.local/bin/wsl-paste" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/"
check_symlink "$HOME/.local/bin/wsl-open" \
  "$DOTFILES_ROOT/platforms/fedora-wsl/stow/interop/"

if [[ -e "$XDG_CONFIG_HOME/ghostty/config" ]]; then
  warning "Ghostty configuration exists in WSL but is not managed by this profile"
else
  pass "Windows owns the terminal; no Ghostty config was deployed in WSL"
fi

ocaml_state="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"
if [[ -f "$ocaml_state" ]]; then
  section "OCaml profile"
  if "$DOTFILES_ROOT/common/verify-ocaml.sh"; then
    pass "OCaml compiler and Platform tools start inside WSL"
  else
    fail "OCaml profile verification failed"
  fi
fi

if [[ "$run_smoke_tests" == "true" ]]; then
  section "Development workflow smoke tests"
  if "$DOTFILES_ROOT/scripts/test-dev-workflows.sh" --all; then
    pass ".NET, Angular/TypeScript and Python workflows"
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
fi

printf '\n'
if ((failures > 0)); then
  printf '%d failure(s), %d warning(s).\n' "$failures" "$warnings" >&2
  exit 1
fi

printf 'Fedora WSL verification passed with %d warning(s).\n' "$warnings"
