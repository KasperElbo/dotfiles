#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

failures=0
pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

require_parrot || exit 1
vm_type="$(require_qemu_vm)" || exit 1
if require_guest_channels; then
  pass "KVM/QEMU guest channels are present ($vm_type)"
else
  exit 1
fi

packages=(
  bat eza fd-find fzf gh git git-delta jq lazygit neovim pipx python3
  python3-venv ripgrep shellcheck spice-vdagent sqlite3 starship stow tmux
  zoxide zsh qemu-guest-agent
)
for package in "${packages[@]}"; do
  status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
  if [[ "$status" == "install ok installed" ]]; then
    pass "$package is APT-owned"
  else
    fail "APT package missing: $package"
  fi
done

commands=(bat eza fd fzf gh git jq lazygit nvim pipx python python3 rg sqlite3 starship stow tmux zoxide zsh)
for command_name in "${commands[@]}"; do
  if command_exists "$command_name"; then
    pass "$command_name is available"
  else
    fail "Command missing: $command_name"
  fi
done

mise_command="$(command -v mise 2>/dev/null || true)"
[[ -n "$mise_command" ]] || mise_command="$HOME/.local/bin/mise"
if [[ -x "$mise_command" ]] && "$mise_command" exec -- uv --version >/dev/null 2>&1; then
  pass "mise-managed uv starts"
else
  fail "mise-managed uv is unavailable"
fi

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
if [[ -r "$state_file" ]] &&
  grep -Fxq 'host_secrets=not-shared' "$state_file" &&
  grep -Fxq 'security_tools=parrot-apt-owned' "$state_file"; then
  pass "CTF guest safety state is recorded"
else
  fail "Parrot CTF safety state is missing"
fi

if ((failures > 0)); then
  printf '\n%d Parrot CTF verification failure(s).\n' "$failures" >&2
  exit 1
fi
printf '\nParrot CTF verification passed.\n'
