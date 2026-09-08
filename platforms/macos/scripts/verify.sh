#!/usr/bin/env bash
set -u

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

failures=0
warnings=0
verify_defaults="false"
verify_containers="false"
verify_tailscale="false"

while (($#)); do
  case "$1" in
  --defaults) verify_defaults="true" ;;
  --containers) verify_containers="true" ;;
  --tailscale) verify_tailscale="true" ;;
  *) die "Unknown option: $1" ;;
  esac
  shift
done

pass() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }
warning() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; warnings=$((warnings + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

check_command() {
  local name="$1"
  local path
  path="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    pass "$name: $path"
  else
    fail "$name not found"
  fi
}

check_arm64_file() {
  local name="$1"
  local path="$2"
  local architecture
  if [[ ! -e "$path" ]]; then
    fail "$name is missing: $path"
    return
  fi
  architecture="$(file -L "$path" 2>/dev/null || true)"
  if [[ "$architecture" == *arm64* || "$architecture" == *universal* ]]; then
    pass "$name is arm64/universal: $path"
  else
    fail "$name does not report arm64 or universal architecture: $architecture"
  fi
}

check_link() {
  local path="$1"
  local prefix="$2"
  local resolved
  if [[ ! -L "$path" ]]; then
    fail "$path is not a Stow symlink"
    return
  fi
  resolved="$(resolve_symlink_target "$path" 2>/dev/null || true)"
  if [[ "$resolved" == "$prefix"* ]]; then
    pass "$path -> $resolved"
  else
    fail "$path resolves outside its owning package: $resolved"
  fi
}

if ! require_apple_silicon_macos; then
  exit 1
fi
activate_homebrew_path

section "Platform security and architecture"
require_native_homebrew
pass "Native Homebrew prefix is /opt/homebrew"
if [[ -x /usr/local/bin/brew ]]; then
  fail "Intel Homebrew is present at /usr/local/bin/brew; remove the duplicate architecture"
else
  pass "No Intel Homebrew executable found"
fi

if csrutil status 2>/dev/null | grep -Fqi enabled; then pass "System Integrity Protection is enabled"; else fail "System Integrity Protection is not enabled"; fi
if spctl --status 2>/dev/null | grep -Fqi enabled; then pass "Gatekeeper is enabled"; else fail "Gatekeeper is not enabled"; fi

section "Commands"
mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -n "$mise_command" ]]; then
  eval "$("$mise_command" activate bash)"
fi
commands=(aerospace ast-grep bat delta dotnet eza fd fzf gh git lazygit mise node npm nvim python rg shellcheck sqlite3 starship stow tmux tree-sitter uv zoxide zsh)
for name in "${commands[@]}"; do check_command "$name"; done

for name in brew nvim node python dotnet; do
  path="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$path" ]] || continue
  architecture="$(file -L "$path" 2>/dev/null || true)"
  if [[ "$architecture" == *arm64* || "$architecture" == *universal* || "$architecture" == *script* || "$architecture" == *text* ]]; then
    pass "$name is native/universal: $path"
  else
    fail "$name does not report arm64 or universal architecture: $architecture"
  fi
done

check_arm64_file "Ghostty" /Applications/Ghostty.app/Contents/MacOS/ghostty
check_arm64_file "AeroSpace" /Applications/AeroSpace.app/Contents/MacOS/AeroSpace
netcoredbg="$XDG_DATA_HOME/nvim/mason/packages/netcoredbg/libexec/netcoredbg/netcoredbg"
check_arm64_file "Mason netcoredbg" "$netcoredbg"

python_arch="$(python -c 'import platform; print(platform.machine())' 2>/dev/null || true)"
if [[ "$python_arch" == arm64 ]]; then
  pass "Python runtime reports arm64"
else
  fail "Python runtime architecture is ${python_arch:-unknown}"
fi
node_arch="$(node -p 'process.arch' 2>/dev/null || true)"
if [[ "$node_arch" == arm64 ]]; then
  pass "Node runtime reports arm64"
else
  fail "Node runtime architecture is ${node_arch:-unknown}"
fi
if dotnet --info 2>/dev/null | grep -Eq 'Architecture:[[:space:]]+arm64'; then
  pass ".NET host/SDK reports arm64"
else
  fail ".NET host/SDK does not report arm64"
fi

# shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
login_check="$(zsh -lic 'printf "%s|%s" "${PATH%%:*}" "$(starship --version >/dev/null && mise --version >/dev/null && printf ready)"' 2>/dev/null || true)"
if [[ "$login_check" == '/opt/homebrew/opt/coreutils/libexec/gnubin|ready' ]]; then
  pass "Zsh login environment activates Homebrew, Starship, and mise"
else
  fail "Zsh login environment is incomplete: ${login_check:-no output}"
fi

login_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
if [[ "$login_shell" == /bin/zsh ]]; then pass "Account login shell is /bin/zsh"; else fail "Account login shell is ${login_shell:-unknown}"; fi

section "Configuration links"
check_link "$HOME/.zshenv" "$DOTFILES_ROOT/zsh/"
check_link "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh/"
check_link "$XDG_CONFIG_HOME/zsh/platform-env.zsh" "$DOTFILES_ROOT/platforms/macos/stow/zsh-platform/"
check_link "$XDG_CONFIG_HOME/zsh/platform.zsh" "$DOTFILES_ROOT/platforms/macos/stow/zsh-platform/"
check_link "$XDG_CONFIG_HOME/aerospace/aerospace.toml" "$DOTFILES_ROOT/platforms/macos/stow/aerospace/"
check_link "$HOME/.local/bin/aerospace-workspace-grid" "$DOTFILES_ROOT/platforms/macos/stow/aerospace/"
check_link "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git/"
check_link "$XDG_CONFIG_HOME/mise/config.toml" "$DOTFILES_ROOT/mise/"
check_link "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim/"
check_link "$XDG_CONFIG_HOME/nvim/lua/plugins/macos.lua" "$DOTFILES_ROOT/platforms/macos/stow/nvim-macos/"

if [[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]]; then pass "Ghostty application is installed"; else fail "Ghostty application is missing"; fi
if [[ -d /Applications/AeroSpace.app ]]; then pass "AeroSpace application is installed"; else fail "AeroSpace application is missing"; fi

if aerospace list-workspaces --focused >/dev/null 2>&1; then
  pass "AeroSpace is running and Accessibility control works"
  if aerospace reload-config --dry-run --no-gui --warnings-as-errors >/dev/null; then
    pass "AeroSpace configuration passes native validation without warnings"
  else
    fail "AeroSpace configuration failed native validation"
  fi
  loaded_config="$(aerospace config --config-path 2>/dev/null || true)"
  if [[ "$loaded_config" == "$XDG_CONFIG_HOME/aerospace/aerospace.toml" ]]; then
    pass "AeroSpace loaded the tracked XDG configuration"
  else
    fail "AeroSpace loaded unexpected config: ${loaded_config:-unknown}"
  fi
else
  warning "AeroSpace CLI cannot reach the window manager; open it and grant Accessibility access"
fi

if [[ "$verify_defaults" == true ]]; then
  section "Managed macOS defaults"
  expected_defaults=(
    'com.apple.dock|autohide|1'
    'com.apple.dock|show-recents|0'
    'com.apple.dock|mru-spaces|0'
    'NSGlobalDomain|AppleShowAllExtensions|1'
    'com.apple.finder|ShowPathbar|1'
  )
  for item in "${expected_defaults[@]}"; do
    IFS='|' read -r domain key expected <<<"$item"
    actual="$(defaults read "$domain" "$key" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      pass "$domain $key = $expected"
    else
      fail "$domain $key expected $expected, got ${actual:-unset}"
    fi
  done
fi

if [[ "$verify_containers" == true ]]; then
  section "Optional Podman machine"
  if podman info >/dev/null 2>&1; then pass "Podman machine is reachable"; else fail "Podman machine is not reachable"; fi
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  if [[ "$rootless" == true ]]; then
    pass "Podman machine connection is rootless"
  else
    fail "Podman reports rootless=${rootless:-unknown}"
  fi
  machine_arch="$(podman run --rm docker.io/library/alpine:latest uname -m 2>/dev/null || true)"
  if [[ "$machine_arch" == aarch64 ]]; then
    pass "Containers run as ARM64"
  else
    fail "Container architecture is ${machine_arch:-unknown}"
  fi
fi

if [[ "$verify_tailscale" == true ]]; then
  section "Optional Tailscale"
  if [[ -d /Applications/Tailscale.app ]]; then
    pass "Tailscale application is installed"
  else
    fail "Tailscale application is missing"
  fi

  tailscale_cli=""
  if [[ -x /usr/local/bin/tailscale ]]; then
    tailscale_cli=/usr/local/bin/tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    tailscale_cli=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi

  if [[ -n "$tailscale_cli" ]]; then
    if version_output="$("$tailscale_cli" version 2>&1)"; then
      pass "tailscale version: $(printf '%s' "$version_output" | head -n1)"
    else
      fail "tailscale version failed"
    fi

    if status_json="$("$tailscale_cli" status --json 2>/dev/null)"; then
      backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"
      case "$backend_state" in
      Running) pass "tailscale status: Running (connected to a tailnet)" ;;
      NeedsLogin | NoState | Stopped | Starting | NeedsMachineAuth)
        pass "tailscale status: $backend_state (installed but not logged in)"
        ;;
      *) warning "tailscale status reported an unrecognized BackendState: ${backend_state:-empty}" ;;
      esac
    else
      warning "'tailscale status --json' did not respond (the daemon may not be running yet)"
    fi
  else
    warning "Tailscale CLI is not installed; enable it from the app's Settings if you want the 'tailscale' command"
  fi
fi

if ((failures > 0)); then
  printf '\n%d macOS verification failure(s); %d warning(s).\n' "$failures" "$warnings" >&2
  exit 1
fi
printf '\nmacOS verification passed with %d warning(s).\n' "$warnings"
