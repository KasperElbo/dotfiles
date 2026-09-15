#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/parrot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/parrot.sh"

verify_reset
manual() { printf '\033[1;33mMANUAL ASSURANCE REQUIRED:\033[0m %s\n' "$*"; }

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
establish_parrot_command_environment

zsh_path="$(resolve_zsh_path 2>/dev/null || true)"
login_shell="$(login_shell_for_user "$(id -un)" 2>/dev/null || true)"
if [[ -n "$zsh_path" ]] && shell_paths_match "$login_shell" "$zsh_path"; then
  pass "Account login shell is the installed Zsh ($login_shell)"
else
  fail "Account login shell is not the installed Zsh: ${login_shell:-unknown}"
fi
if [[ -n "${SHELL:-}" ]] && shell_paths_match "$SHELL" "$zsh_path"; then
  pass "Current login session reports Zsh in SHELL"
else
  manual "start a new graphical login session, then confirm SHELL and the Konsole process use $zsh_path"
fi
if zsh -lic 'exit 0' >/dev/null 2>&1; then
  pass "Zsh login startup succeeds"
else
  fail "Zsh login startup failed"
fi

packages=(
  bat eza fd-find fontconfig fzf gh git git-delta jq konsole lazygit pipx python3
  python3-venv ripgrep shellcheck spice-vdagent sqlite3 starship stow tmux
  xclip xxd xz-utils zoxide zsh qemu-guest-agent
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
if [[ -n "$mise_command" ]] &&
  run_mise "$mise_command" exec -- uv --version >/dev/null 2>&1; then
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
  nvim_path="$(run_mise "$mise_command" which nvim 2>/dev/null || true)"
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
    run_mise "$mise_command" exec -- nvim --version 2>/dev/null |
      sed -n '1s/^NVIM v\([0-9][0-9.]*\).*/\1/p'
  )"
fi
check_version_at_least "Neovim" "$nvim_version" "0.12"

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
  else
    fail "$command_name is installed by Parrot but is not resolvable in the supported environment"
    command_diagnostics "$command_name"
  fi
done

for required_path in /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
  case ":$PATH:" in
  *":$required_path:"*) pass "PATH retains $required_path" ;;
  *) fail "PATH is missing standard Parrot directory: $required_path" ;;
  esac
done

duplicate_paths="$(
  tr ':' '\n' <<<"$PATH" | awk 'NF && seen[$0]++ { print }' | sort -u
)"
if [[ -z "$duplicate_paths" ]]; then
  pass "PATH entries are unique"
else
  fail "PATH contains duplicate entries: ${duplicate_paths//$'\n'/, }"
fi
if [[ -d /snap/bin ]]; then
  case ":$PATH:" in
  *:/snap/bin:*) pass "PATH retains the installed Snap command directory" ;;
  *) fail "PATH is missing the installed Snap command directory: /snap/bin" ;;
  esac
else
  pass "Snap is absent, so /snap/bin is deliberately omitted"
fi

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

font_family="$(fc-match --format='%{family}\n' 'Hack Nerd Font Mono' 2>/dev/null || true)"
if grep -Fq 'Hack Nerd Font Mono' <<<"$font_family"; then
  pass "Hack Nerd Font Mono is available to fontconfig"
else
  fail "Hack Nerd Font Mono is not available to fontconfig"
fi
font_file="$(fc-match --format='%{file}\n' 'Hack Nerd Font Mono' 2>/dev/null || true)"
font_charset="$(fc-query --format='%{charset}\n' "$font_file" 2>/dev/null || true)"
if grep -Eq 'e0b0(-e0c8)?' <<<"$font_charset" &&
  grep -Eq 'f000(-f381)?' <<<"$font_charset"; then
  pass "Terminal font covers representative Starship Powerline and Nerd Font glyphs"
else
  fail "Terminal font lacks representative Starship glyph coverage"
fi

konsole_profile="$XDG_DATA_HOME/konsole/Dotfiles-Parrot-CTF.profile"
konsolerc="$XDG_CONFIG_HOME/konsolerc"
if grep -Fxq 'Font=Hack Nerd Font Mono,10,-1,5,50,0,0,0,0,0' "$konsole_profile" 2>/dev/null &&
  ! grep -Eq '^[[:space:]]*Command=' "$konsole_profile" 2>/dev/null; then
  pass "Parrot Konsole profile selects the Nerd Font and inherits the account shell"
else
  fail "Parrot Konsole profile font or shell-inheritance policy is incorrect"
fi
if grep -Eq '^DefaultProfile=Dotfiles-Parrot-CTF\.profile$' "$konsolerc" 2>/dev/null; then
  pass "Dotfiles Parrot CTF is the effective Konsole profile"
else
  fail "Dotfiles Parrot CTF is not the effective Konsole profile"
fi

missing_bat_themes=()
for flavour in Latte Frappe Macchiato Mocha; do
  bat --list-themes 2>/dev/null | grep -Fxq "Catppuccin $flavour" ||
    missing_bat_themes+=("$flavour")
done
if ((${#missing_bat_themes[@]} == 0)); then
  pass "Bat provides every Catppuccin syntax theme referenced by Delta"
else
  fail "Bat is missing Catppuccin themes: ${missing_bat_themes[*]}"
fi

# verifies: vm-guest
#
# The Parrot CTF profile owns the guest agents that config/capabilities.tsv
# records as the vm-guest capability on this platform; the marker says so in
# the spelling scripts/validate-capabilities.py checks for.
check_system_service_active qemu-guest-agent.service
check_system_service_active spice-vdagentd.socket

printf '\nGuest isolation evidence\n'
default_route="$(ip route show default 2>/dev/null | head -n 1)"
if [[ -n "$default_route" && "$default_route" == *' dev '* ]]; then
  printf 'VERIFIED: default route/interface observed: %s\n' "$default_route"
else
  fail "No default route/interface is observable"
fi

shared_mounts="$(
  findmnt --raw --noheadings --output FSTYPE,TARGET,SOURCE 2>/dev/null |
    awk '$1 == "9p" || $1 == "virtiofs" { print }'
)"
if [[ -z "$shared_mounts" ]]; then
  printf 'NOT OBSERVED: mounted 9p or virtiofs host filesystem\n'
else
  fail "Host filesystem passthrough is mounted: ${shared_mounts//$'\n'/; }"
fi

runtime_dir="/run/user/$(id -u)"
for socket_name in SSH_AUTH_SOCK GPG_AGENT_INFO; do
  socket_path="${!socket_name:-}"
  if [[ -z "$socket_path" ]]; then
    printf 'NOT OBSERVED: %s forwarding socket\n' "$socket_name"
  elif [[ "$socket_path" == "$runtime_dir/"* ]]; then
    printf 'VERIFIED: %s uses a guest runtime path: %s\n' "$socket_name" "$socket_path"
    manual "confirm the local process behind $socket_name is not backed by an added host channel"
  else
    manual "review nonstandard $socket_name path: $socket_path"
  fi
done
if command_exists gpgconf; then
  gpg_socket="$(gpgconf --list-dirs agent-socket 2>/dev/null || true)"
  if [[ "$gpg_socket" == "$runtime_dir/"* ]]; then
    printf 'VERIFIED: GPG agent socket uses a guest runtime path: %s\n' "$gpg_socket"
  elif [[ -n "$gpg_socket" ]]; then
    manual "review nonstandard GPG agent socket path: $gpg_socket"
  else
    printf 'NOT OBSERVED: GPG agent socket\n'
  fi
else
  printf 'NOT OBSERVED: gpgconf-based GPG agent socket evidence\n'
fi
manual "guest observations cannot prove libvirt NAT, absence of inactive passthrough devices, or host-side forwarding; run the host verifier with --domain"

section "Stow ownership"
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/zsh-platform"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/zsh-platform"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/mise-ctf"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim"
check_symlink "$XDG_CONFIG_HOME/dotfiles/neovim-profile" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/neovim-profile"
check_symlink "$HOME/.tmux.conf" "$DOTFILES_ROOT/tmux"
check_symlink "$HOME/.local/bin/bat" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/command-shims"
check_symlink "$HOME/.local/bin/fd" \
  "$DOTFILES_ROOT/platforms/parrot-ctf/stow/command-shims"

state_file="$XDG_CONFIG_HOME/dotfiles/parrot-ctf.conf"
if profile_state_validate_file "$state_file" parrot-ctf &&
  [[ "$(profile_state_read "$state_file" host_secrets parrot-ctf)" == not-shared ]] &&
  [[ "$(profile_state_read "$state_file" security_tools parrot-ctf)" == parrot-apt-owned ]]; then
  pass "CTF guest installer intent is recorded (not isolation proof)"
else
  fail "Parrot CTF safety state is missing or invalid"
fi

finish_verification "Parrot CTF verification"
