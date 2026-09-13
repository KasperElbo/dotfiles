#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

failures=0
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

command_diagnostics() {
  local command_name="$1"
  printf '  command -v: %s\n' "$(command -v "$command_name" 2>/dev/null || printf 'missing')" >&2
  type -a "$command_name" >&2 2>/dev/null || true
}

is_apt_owned_command() {
  local command_name="$1"
  local command_path
  local resolved_path

  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  [[ "$command_path" == /* ]] || return 1
  resolved_path="$(realpath -e "$command_path" 2>/dev/null || printf '%s' "$command_path")"

  [[ "$command_path" != "$HOME/"* && "$resolved_path" != "$HOME/"* ]] || return 1
  dpkg-query -S "$command_path" >/dev/null 2>&1 ||
    dpkg-query -S "$resolved_path" >/dev/null 2>&1
}

version_is_supported() {
  local version="$1"
  local major minor

  [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  ((major > 0 || (major == 0 && minor >= 12)))
}

require_parrot || exit 1
vm_type="$(require_qemu_vm)" || exit 1
if require_guest_channels; then
  pass "KVM/QEMU guest channels are present ($vm_type)"
else
  exit 1
fi

# Match the environment installed for the next login shell. Verification must
# not depend on whether the caller has restarted Bash/Zsh since installation.
establish_user_tool_environment

packages=(
  bat eza fd-find fzf gh git git-delta jq lazygit pipx python3
  python3-venv ripgrep shellcheck spice-vdagent sqlite3 starship stow tmux
  xclip xxd zoxide zsh qemu-guest-agent
)
for package in "${packages[@]}"; do
  status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
  if [[ "$status" == "install ok installed" ]]; then
    pass "$package is APT-owned"
  else
    fail "APT package missing: $package"
  fi
done

commands=(bat eza fd fzf gh git jq lazygit nvim pipx python python3 rg sqlite3 starship stow tmux xclip xxd zoxide zsh)
for command_name in "${commands[@]}"; do
  if command_exists "$command_name"; then
    pass "$command_name is available"
  else
    fail "Command missing: $command_name"
  fi
done

for command_name in bat fd; do
  if "$command_name" --version >/dev/null 2>&1; then
    pass "$command_name starts in the intended install-time PATH"
  else
    fail "$command_name is present but cannot start"
    command_diagnostics "$command_name"
  fi
done

mise_command="$(resolve_mise_command 2>/dev/null || true)"
if [[ -n "$mise_command" ]] && "$mise_command" exec -- uv --version >/dev/null 2>&1; then
  pass "mise-managed uv starts"
else
  fail "mise-managed uv is unavailable"
fi

mise_config="$XDG_CONFIG_HOME/mise/config.toml"
mapfile -t mise_tools < <(
  awk '
    /^\[tools\]$/ { in_tools = 1; next }
    /^\[/ { in_tools = 0 }
    in_tools && /^[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*=/ {
      key = $0
      sub(/[[:space:]]*=.*/, "", key)
      sub(/^[[:space:]]*/, "", key)
      print key
    }
  ' "$mise_config" 2>/dev/null | sort
)
if [[ "${mise_tools[*]}" == "nvim uv" ]] &&
  grep -Fqx 'nvim = "github:neovim/neovim"' "$mise_config"; then
  pass "Parrot mise manifest is limited to uv and the Neovim exception"
else
  fail "Unexpected Parrot mise tools: ${mise_tools[*]:-(unreadable manifest)}"
fi

nvim_path=""
if [[ -n "$mise_command" ]]; then
  nvim_path="$("$mise_command" which nvim 2>/dev/null || true)"
fi
mise_data_dir="${MISE_DATA_DIR:-$XDG_DATA_HOME/mise}"
if [[ -x "$nvim_path" && "$nvim_path" == "$mise_data_dir/installs/"* ]]; then
  pass "Neovim resolves to the mise-managed installation"
else
  fail "Neovim is not resolved from mise: ${nvim_path:-missing}"
  command_diagnostics nvim
fi

nvim_version=""
if [[ -n "$mise_command" ]]; then
  nvim_version="$(
    "$mise_command" exec -- nvim --version 2>/dev/null |
      sed -n '1s/^NVIM v\([0-9][0-9.]*\).*/\1/p'
  )"
fi
if version_is_supported "$nvim_version"; then
  pass "Neovim $nvim_version satisfies the >= 0.12 baseline"
else
  fail "Neovim >= 0.12 required; resolved version: ${nvim_version:-unknown}"
fi

nvim_log="$(mktemp)"
if [[ -n "$mise_command" ]] &&
  DOTFILES_NVIM_PROFILE=parrot-ctf timeout --kill-after=10s 2m \
    "$mise_command" exec -- nvim --headless +qa >"$nvim_log" 2>&1; then
  pass "Reduced LazyVim profile starts headlessly"
else
  fail "Reduced LazyVim profile failed headless startup"
  sed 's/^/  /' "$nvim_log" >&2
fi
rm -f -- "$nvim_log"

parrot_lock="$XDG_CONFIG_HOME/nvim/profiles/parrot-ctf/lazy-lock.json"
plugin_lock_failures=0
plugin_lock_entries=0
while IFS=$'\t' read -r plugin_name expected_commit; do
  [[ -n "$plugin_name" && -n "$expected_commit" ]] || continue
  plugin_lock_entries=$((plugin_lock_entries + 1))
  plugin_dir="$XDG_DATA_HOME/nvim/lazy/$plugin_name"
  actual_commit="$(git -C "$plugin_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    fail "Lazy plugin lock mismatch: $plugin_name (expected $expected_commit, found ${actual_commit:-missing})"
    plugin_lock_failures=$((plugin_lock_failures + 1))
  fi
done < <(jq -r 'to_entries[] | [.key, .value.commit] | @tsv' "$parrot_lock" 2>/dev/null)
if ((plugin_lock_entries > 0 && plugin_lock_failures == 0)); then
  pass "Reduced LazyVim plugins match the Parrot lockfile"
elif ((plugin_lock_entries == 0)); then
  fail "Parrot LazyVim lockfile is missing or empty: $parrot_lock"
fi

expected_mason_file="$XDG_CONFIG_HOME/nvim/profiles/parrot-ctf/mason-packages.txt"
mason_root="$XDG_DATA_HOME/nvim/mason/packages"
mapfile -t expected_mason < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$expected_mason_file" 2>/dev/null | sort)
mapfile -t actual_mason < <(
  if [[ -d "$mason_root" ]]; then
    find "$mason_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
  fi
)
if [[ "${actual_mason[*]}" == "${expected_mason[*]}" && ${#expected_mason[@]} -gt 0 ]]; then
  pass "Mason inventory exactly matches the reduced Parrot profile"
else
  fail "Mason inventory mismatch"
  printf '  expected: %s\n  actual:   %s\n' "${expected_mason[*]:-(empty)}" "${actual_mason[*]:-(empty)}" >&2
fi

for command_name in python python3; do
  if is_apt_owned_command "$command_name"; then
    pass "$command_name remains Parrot/APT-owned"
  else
    fail "$command_name is missing or shadowed by a user/mise executable"
    command_diagnostics "$command_name"
  fi
done

protected_tools=(nmap hashcat john sqlmap gobuster ffuf hydra)
for command_name in "${protected_tools[@]}"; do
  if [[ -e "$HOME/.local/bin/$command_name" || -e "$mise_data_dir/shims/$command_name" ]]; then
    fail "Protected security-tool shim present: $command_name"
    command_diagnostics "$command_name"
  elif command_exists "$command_name"; then
    if is_apt_owned_command "$command_name"; then
      pass "$command_name remains Parrot/APT-owned"
    else
      fail "$command_name is shadowed by a non-APT executable"
      command_diagnostics "$command_name"
    fi
  fi
done

for required_path in /usr/bin /bin; do
  case ":$PATH:" in
  *":$required_path:"*) pass "PATH retains $required_path" ;;
  *) fail "PATH is missing standard Parrot directory: $required_path" ;;
  esac
done

selected_theme="macchiato"
theme_file="$XDG_CONFIG_HOME/dotfiles/theme"
if [[ -r "$theme_file" ]]; then
  read -r selected_theme <"$theme_file" || true
fi
starship_config="$XDG_CONFIG_HOME/starship/catppuccin-${selected_theme}.toml"
starship_log="$(mktemp)"
if TERM=xterm-256color STARSHIP_CONFIG="$starship_config" STARSHIP_SHELL=zsh \
  starship prompt >/dev/null 2>"$starship_log" &&
  ! grep -Eiq '(warn|error|failed to load config)' "$starship_log"; then
  pass "Starship config loads cleanly"
else
  fail "Starship config emitted a warning or error"
  sed 's/^/  /' "$starship_log" >&2
fi
rm -f -- "$starship_log"

if systemctl is-active --quiet qemu-guest-agent.service; then
  pass "qemu-guest-agent is active"
else
  fail "qemu-guest-agent is not active"
fi
if systemctl is-active --quiet spice-vdagentd.socket; then
  pass "SPICE guest socket is active"
else
  fail "SPICE guest socket is not active"
fi

links=(
  "$HOME/.zshenv"
  "$XDG_CONFIG_HOME/zsh/.zshrc"
  "$XDG_CONFIG_HOME/zsh/platform.zsh"
  "$XDG_CONFIG_HOME/git/config"
  "$XDG_CONFIG_HOME/mise/config.toml"
  "$XDG_CONFIG_HOME/nvim/init.lua"
  "$XDG_CONFIG_HOME/dotfiles/neovim-profile"
  "$HOME/.tmux.conf"
  "$HOME/.local/bin/bat"
  "$HOME/.local/bin/fd"
)
for link in "${links[@]}"; do
  if [[ -L "$link" ]]; then
    pass "$link is managed by Stow"
  else
    fail "Missing Stow link: $link"
  fi
done

state_file="$XDG_CONFIG_HOME/dotfiles/parrot-ctf.conf"
if profile_state_validate_file "$state_file" parrot-ctf &&
  [[ "$(profile_state_read "$state_file" host_secrets parrot-ctf)" == not-shared ]] &&
  [[ "$(profile_state_read "$state_file" security_tools parrot-ctf)" == parrot-apt-owned ]]; then
  pass "CTF guest safety state is recorded"
else
  fail "Parrot CTF safety state is missing"
fi

if ((failures > 0)); then
  printf '\n%d Parrot CTF verification failure(s).\n' "$failures" >&2
  exit 1
fi
printf '\nParrot CTF verification passed.\n'
