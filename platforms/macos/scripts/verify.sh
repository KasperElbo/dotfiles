#!/usr/bin/env bash
set -u

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

verify_reset
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

if csrutil status 2>/dev/null | grep -Fqi enabled; then
  pass "System Integrity Protection is enabled"
elif macos_is_github_hosted_runner; then
  not_observed "System Integrity Protection is not observable as enabled on hosted macOS; verify it on a real machine"
else
  fail "System Integrity Protection is not enabled"
fi
if spctl --status 2>/dev/null | grep -Fqi enabled; then pass "Gatekeeper is enabled"; else fail "Gatekeeper is not enabled"; fi

section "Commands"
mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -n "$mise_command" ]]; then
  eval "$("$mise_command" activate bash)"
fi
commands=(aerospace ast-grep bat delta dotnet dotnet-easydotnet eza fd fzf gh git jq lazygit mise node npm nvim python rg scp sftp shellcheck sqlite3 ssh starship stow tmux tree-sitter uv zoxide zsh)
for name in "${commands[@]}"; do check_command "$name"; done

# ---------------------------------------------------------------------------
# SFTP client baseline
#
# macOS deliberately declares no SSH package: the Brewfile installs none, and
# the client this repository promises is Apple's own system OpenSSH in
# /usr/bin. Checking only that an "sftp" command exists would accept a
# Homebrew or third-party client that silently replaced it, which is exactly
# the second SSH implementation this platform is documented as not having.
# ---------------------------------------------------------------------------

section "SFTP client baseline"

for name in sftp scp ssh; do
  resolved="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    fail "$name not found; macOS ships it in /usr/bin"
    continue
  fi
  # Compare the real path, so neither a symlinked PATH entry nor a Homebrew
  # shim decides the answer by spelling.
  canonical="$(verify_canonical_existing_path "$resolved" 2>/dev/null || true)"
  if [[ "${canonical:-$resolved}" == /usr/bin/"$name" ]]; then
    pass "$name is Apple's system OpenSSH: ${canonical:-$resolved}"
  else
    fail "$name resolves to ${canonical:-$resolved}, not Apple's system" \
      "OpenSSH at /usr/bin/$name; this platform installs no second SSH" \
      "implementation"
  fi
done

ssh_version="$(ssh -V 2>&1 || true)"
if [[ "$ssh_version" == *OpenSSH* ]]; then
  pass "ssh -V: $ssh_version"
else
  fail "ssh -V did not report an OpenSSH client: ${ssh_version:-no output}"
fi

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
check_easy_dotnet_debugger osx-arm64
check_arm64_file "EasyDotnet bundled netcoredbg" "$EASY_DOTNET_DEBUGGER_PATH"

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

# gnubin exists to supply GNU tools macOS does not ship — timeout, used by the
# shared Neovim bootstrap — and deliberately does not shadow Apple's coreutils.
# Assert that resolution rather than a PATH position: /etc/zprofile runs
# path_helper after .zshenv, so no entry from .zshenv keeps a fixed index in a
# login shell, and mise-managed tools legitimately take the front.
# Assert the promise Homebrew coreutils is here to keep, not a PATH position:
# a GNU timeout for the shared Neovim bootstrap, with Apple's own coreutils
# left in front. Position cannot be asserted because /etc/zprofile runs
# path_helper after .zshenv, and mise-managed tools legitimately take the
# front; the provider is not asserted either, since any Homebrew path may
# supply timeout as long as it is the GNU one.
# shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
login_check="$(zsh -lic 'printf "%s|%s|%s" "$(timeout --version 2>/dev/null | head -n1)" "$(command -v ls)" "$(starship --version >/dev/null && mise --version >/dev/null && printf ready)"' 2>/dev/null || true)"
login_timeout="${login_check%%|*}"
login_rest="${login_check#*|}"
login_ls="${login_rest%%|*}"
login_tools="${login_check##*|}"
if [[ "$login_tools" != ready ]]; then
  fail "Zsh login environment does not activate Starship and mise: ${login_check:-no output}"
elif [[ "$login_timeout" != *"GNU coreutils"* ]]; then
  fail "Zsh login shell does not provide GNU timeout: ${login_timeout:-not found}"
elif [[ "$login_ls" == *"/coreutils/libexec/gnubin/"* ]]; then
  fail "Zsh login shell shadows Apple's coreutils with gnubin: $login_ls"
else
  pass "Zsh login environment activates Homebrew, Starship, and mise"
fi

# Apple's /bin/zsh and a deliberately selected Homebrew Zsh are both supported,
# so this asserts registration in /etc/shells rather than one exact path.
login_shell="$(macos_login_shell_for_user "$USER" || true)"
if macos_login_shell_is_compliant "$login_shell"; then
  pass "Account login shell is a registered Zsh: $login_shell"
else
  fail "Account login shell is not a registered Zsh: ${login_shell:-unknown}"
fi

section "Configuration links"
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh/"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh/"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" "$DOTFILES_ROOT/platforms/macos/stow/zsh-platform/"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" "$DOTFILES_ROOT/platforms/macos/stow/zsh-platform/"
check_symlink "$XDG_CONFIG_HOME/aerospace/aerospace.toml" "$DOTFILES_ROOT/platforms/macos/stow/aerospace/"
check_symlink "$HOME/.local/bin/aerospace-workspace-grid" "$DOTFILES_ROOT/platforms/macos/stow/aerospace/"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git/"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" "$DOTFILES_ROOT/mise/"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim/"
check_symlink "$XDG_CONFIG_HOME/nvim/lua/plugins/macos.lua" "$DOTFILES_ROOT/platforms/macos/stow/nvim-macos/"

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

# ---------------------------------------------------------------------------
# Optional AI-assisted development profile
#
# The shared installer and verifier own the profile itself; this section adds
# only what is genuinely a macOS question. Two things must be true here that
# are not true anywhere else: every advertised command has to be usable on
# arm64, and none of them may have arrived through Homebrew or a global npm
# install competing with the mise-managed copy.
# ---------------------------------------------------------------------------

section "AI-assisted development profile"

ai_state="$XDG_CONFIG_HOME/dotfiles/ai.conf"
agents_source="$DOTFILES_ROOT/common/assets/AGENTS.md"
codex_home="${CODEX_HOME:-$HOME/.codex}"

macos_ai_is_agents_symlink() {
  [[ -L "$1" ]] &&
    [[ "$(verify_canonical_existing_path "$1" 2>/dev/null || true)" == \
      "$(verify_canonical_existing_path "$agents_source" 2>/dev/null || true)" ]]
}

# A Mach-O that is not arm64 would run under Rosetta, which this platform
# refuses. Scripts and text are fine: they execute under the arm64 Node and
# Python runtimes already verified above.
macos_ai_check_native_architecture() {
  local name="$1" resolved canonical architecture

  resolved="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 0
  canonical="$(verify_canonical_existing_path "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  architecture="$(file -L "$canonical" 2>/dev/null || true)"
  case "$architecture" in
  *arm64* | *universal* | *script* | *text* | *link*)
    pass "$name runs natively on arm64: $canonical"
    ;;
  *x86_64* | *i386*)
    fail "$name is an Intel-only binary and would need Rosetta: $architecture"
    ;;
  *)
    not_observed "$name architecture could not be read from ${canonical:-unknown}"
    ;;
  esac
}

# mise owns every AI command. Homebrew and a global npm prefix are the two ways
# a second copy could appear on this platform, so both are ruled out explicitly
# rather than inferred from whichever copy PATH happened to find first.
macos_ai_check_no_duplicate_provider() {
  local name="$1" resolved canonical

  resolved="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 0
  canonical="$(verify_canonical_existing_path "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  if [[ "$canonical" == /opt/homebrew/* || "$canonical" == /usr/local/* ]]; then
    fail "$name resolves to a Homebrew-owned copy at $canonical; the AI profile is mise-owned"
  else
    pass "$name is not a Homebrew duplicate: $canonical"
  fi
}

if [[ -f "$ai_state" ]]; then
  if "$DOTFILES_ROOT/common/verify-ai.sh"; then
    pass "AI profile verification completed"
  else
    fail "AI profile verification failed"
  fi

  ai_commands=(claude herdr)
  while IFS='=' read -r ai_component ai_ownership; do
    case "$ai_component:$ai_ownership" in
    codex:mise-npm) ai_commands+=(codex) ;;
    gnhf:mise-npm) ai_commands+=(gnhf) ;;
    gh_axi:mise-npm) ai_commands+=(gh-axi) ;;
    chrome_devtools_axi:mise-npm) ai_commands+=(chrome-devtools-axi) ;;
    lavish_axi:mise-npm) ai_commands+=(lavish-axi) ;;
    tasks_axi:mise-npm) ai_commands+=(tasks-axi) ;;
    quota_axi:mise-npm) ai_commands+=(quota-axi) ;;
    backpass:mise-npm) ai_commands+=(backpass) ;;
    acpx:mise-npm) ai_commands+=(acpx) ;;
    treehouse:installed) ai_commands+=(treehouse) ;;
    no_mistakes:installed) ai_commands+=(no-mistakes) ;;
    esac
  done <"$ai_state"

  for name in "${ai_commands[@]}"; do
    macos_ai_check_native_architecture "$name"
    macos_ai_check_no_duplicate_provider "$name"
  done

  global_npm="$(npm ls --global --depth=0 --parseable 2>/dev/null || true)"
  npm_duplicate="false"
  for package in @anthropic-ai/claude-code @openai/codex gnhf backpass acpx \
    gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi; do
    if [[ "$global_npm" == *"/node_modules/$package" ]] ||
      [[ "$global_npm" == *"/node_modules/$package"$'\n'* ]]; then
      fail "$package is also installed globally with npm; the AI profile is mise-owned"
      npm_duplicate="true"
    fi
  done
  [[ "$npm_duplicate" == true ]] ||
    pass "No AI package is duplicated in a global npm prefix"

  # A command that only works because this verifier's process activated mise is
  # not actually installed for the user. Prove it resolves in a fresh login.
  for name in "${ai_commands[@]}"; do
    if zsh -lic 'command -v "$1" >/dev/null' _ "$name" >/dev/null 2>&1; then
      pass "Fresh Zsh login resolves $name"
    else
      fail "Fresh Zsh login does not resolve $name"
    fi
  done
  if zsh -lic 'claude --version >/dev/null' >/dev/null 2>&1; then
    pass "Claude Code starts in a fresh Zsh login"
  else
    fail "Claude Code does not start in a fresh Zsh login"
  fi
else
  if [[ -f "$XDG_CONFIG_HOME/mise/conf.d/ai.toml" ||
    -e "$HOME/.local/bin/treehouse" ||
    -d "$XDG_DATA_HOME/firstmate" ]] ||
    macos_ai_is_agents_symlink "$HOME/.claude/CLAUDE.md" ||
    macos_ai_is_agents_symlink "$codex_home/AGENTS.md" ||
    macos_ai_is_agents_symlink "$XDG_CONFIG_HOME/opencode/AGENTS.md"; then
    fail "AI profile is not selected, but AI-owned files remain (run" \
      "common/install-ai.sh, or remove them by hand)"
  else
    pass "AI profile is not installed (not selected)"
  fi
fi

# ---------------------------------------------------------------------------
# Optional OCaml profile
#
# Selection is read from the authoritative install/profile state rather than
# forwarded as a flag, so a standalone verifier run reaches the same verdict as
# one inside the installer, and an unselected profile is never failed for a
# missing opam. The shared verifier is the only OCaml implementation; macOS
# adds no second one.
# ---------------------------------------------------------------------------

section "Optional OCaml profile"

# The platform, not the shared verifier, knows which prefix its native provider
# owns. Passing it in keeps opam ownership provable without teaching portable
# code about Homebrew.
if DOTFILES_NATIVE_PREFIX="$("$(homebrew_path)" --prefix)" \
  "$DOTFILES_ROOT/common/verify-ocaml.sh"; then
  pass "OCaml profile verification completed"
else
  fail "OCaml profile verification failed"
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
  # network-source: smoke-image-alpine
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

finish_verification "macOS verification"
