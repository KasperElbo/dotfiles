#!/usr/bin/env bash
set -u

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"
# shellcheck source=../lib/dictation.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/dictation.sh"
# shellcheck source=../../../common/lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/tool-floors.sh"

verify_reset
verify_defaults="false"
verify_containers="false"
verify_tailscale="false"
verify_dictation="false"

while (($#)); do
  case "$1" in
  --defaults) verify_defaults="true" ;;
  --containers) verify_containers="true" ;;
  --tailscale) verify_tailscale="true" ;;
  --dictation) verify_dictation="true" ;;
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
# Every command is run, not only found: a stale Homebrew link or a binary for
# the wrong architecture still resolves on PATH. aerospace is checked for
# resolution only, because its CLI talks to the running window manager, which
# the AeroSpace checks below report on their own terms.
commands=(bat delta eza fd fzf gh git jq mise nvim rg scp sftp shellcheck sqlite3 ssh starship stow tmux zoxide zsh)
for name in "${commands[@]}"; do check_command "$name" --probe; done
check_command aerospace

section "mise-owned runtimes"
# mise owns these runtimes on every platform. On macOS a Homebrew formula of
# the same name is the likely second copy, so each must resolve to the
# mise-managed one in the PATH a fresh Zsh login configures, not merely exist.
# shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
VERIFY_CONFIGURED_LOGIN_PATH="$(
  zsh -lic 'printf "\n__DOTFILES_VERIFY_PATH__%s\n" "$PATH"' 2>/dev/null |
    sed -n 's/^__DOTFILES_VERIFY_PATH__//p' |
    tail -n 1
)"
VERIFY_CALLER_PATH="$PATH"
VERIFY_MISE_COMMAND="$mise_command"
check_mise_context
mise_tools=(ast-grep dotnet dotnet-easydotnet lazygit neovim-node-host node npm python tree-sitter uv)
for name in "${mise_tools[@]}"; do check_mise_owned "$name"; done

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
check_symlink "$XDG_CONFIG_HOME/ghostty/macos.conf" "$DOTFILES_ROOT/platforms/macos/stow/ghostty-macos/"

# verifies: terminal -- Ghostty is the macOS terminal, installed from the
# Brewfile with the baseline.
ghostty_binary=/Applications/Ghostty.app/Contents/MacOS/ghostty
if [[ -x "$ghostty_binary" ]]; then
  pass "Ghostty application is installed"
  # An include chain decides this, not any one tracked file, so ask Ghostty
  # what it resolved. Left Option has to arrive as Alt for fzf's shared Alt-C
  # directory picker; Right Option stays a macOS modifier for symbol entry.
  if "$ghostty_binary" +show-config 2>/dev/null |
    grep -Eq '^macos-option-as-alt[[:space:]]*=[[:space:]]*left$'; then
    pass "Ghostty sends Left Option as Alt, leaving Right Option for symbol entry"
  else
    fail "Ghostty does not resolve macos-option-as-alt = left; fzf's Alt-C will not reach the shell"
  fi
else
  fail "Ghostty application is missing"
fi
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
# Machine-local theme
#
# The installer applies the selected Catppuccin flavour through the portable
# theme command. Prove the result a new terminal sees: a valid recorded
# flavour, the Starship configuration for that flavour, the derived Delta,
# Ghostty and tmux overrides, and a fresh Zsh login that selects the matching
# Starship configuration and bat theme.
# ---------------------------------------------------------------------------

section "Theme"

# The hook the portable theme command sources on this platform. It is checked
# here rather than with the other Stow links because it is theme integration:
# a Mac missing it is one where `theme` silently does no desktop work.
check_symlink "$XDG_CONFIG_HOME/dotfiles/theme-hooks.d/macos.sh" \
  "$DOTFILES_ROOT/platforms/macos/stow/theme-hooks/"
for flavour in latte frappe macchiato mocha; do
  check_symlink "$XDG_DATA_HOME/wallpapers/catppuccin-${flavour}.webp" \
    "$DOTFILES_ROOT/theme-assets/"
done

theme_file="$XDG_CONFIG_HOME/dotfiles/theme"
current_theme=""
[[ ! -r "$theme_file" ]] || current_theme="$(tr -d '[:space:]' <"$theme_file")"

case "$current_theme" in
latte | frappe | macchiato | mocha)
  pass "Current Catppuccin flavour: $current_theme"
  ;;
"")
  fail "Theme state is missing or empty: $theme_file"
  ;;
*)
  fail "Invalid Catppuccin flavour in $theme_file: $current_theme"
  current_theme=""
  ;;
esac

if [[ -n "$current_theme" ]]; then
  starship_config="$XDG_CONFIG_HOME/starship/catppuccin-${current_theme}.toml"
  check_file_contains "Starship configuration selects the $current_theme palette" \
    "$starship_config" "palette = 'catppuccin_${current_theme}'"
  check_file_contains "Delta local theme override matches" \
    "$XDG_CONFIG_HOME/dotfiles/git-theme" "features = catppuccin-${current_theme}"
  check_file_contains "Ghostty local theme override matches" \
    "$XDG_CONFIG_HOME/dotfiles/ghostty.conf" "theme = catppuccin-${current_theme}.conf"
  check_file_contains "tmux local theme override matches" \
    "$XDG_CONFIG_HOME/dotfiles/tmux-theme.conf" "@catppuccin_flavor \"${current_theme}\""

  bat_theme="Catppuccin $(tr '[:lower:]' '[:upper:]' <<<"${current_theme:0:1}")${current_theme:1}"
  if bat --list-themes 2>/dev/null | grep -Fxq "$bat_theme"; then
    pass "bat provides the selected syntax theme: $bat_theme"
  else
    fail "bat does not provide the selected syntax theme: $bat_theme"
  fi

  # shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
  login_theme="$(
    zsh -lic 'printf "\n__DOTFILES_VERIFY_THEME__%s|%s\n" "${STARSHIP_CONFIG:-}" "${BAT_THEME:-}"' \
      2>/dev/null |
      sed -n 's/^__DOTFILES_VERIFY_THEME__//p' |
      tail -n 1
  )"
  if [[ "${login_theme%%|*}" == "$starship_config" ]]; then
    pass "Zsh login selects the $current_theme Starship configuration"
  else
    fail "Zsh login STARSHIP_CONFIG is ${login_theme%%|*}; expected $starship_config"
  fi
  if [[ "${login_theme#*|}" == "$bat_theme" ]]; then
    pass "Zsh login selects the $bat_theme bat theme"
  else
    fail "Zsh login BAT_THEME is ${login_theme#*|}; expected $bat_theme"
  fi
fi

# ---------------------------------------------------------------------------
# Neovim tooling and the Catppuccin tmux theme
#
# Both are installed by the macOS installer from the same tracked sources as
# every other workstation: the Mason inventory and the pinned tmux plugin.
# ---------------------------------------------------------------------------

section "Neovim tooling"
check_version_at_least "Neovim" "$(tool_version nvim)" "$(tool_floor nvim)"
check_mason_inventory "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"

section "Catppuccin tmux"
check_catppuccin_tmux

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

ai_state="$(verify_optional_capability_state macos ai || true)"
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

ai_disposition="$(verify_optional_capability_disposition macos ai || true)"

case "$ai_disposition" in
verify | leftover)
  verify_optional_capability_report "AI profile" "$ai_state" "$ai_disposition"

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

  # The global npm prefix is ruled out by common/verify-ai.sh, which runs on
  # every platform that selects the AI profile. It used to be checked only
  # here, which left the same duplicate undetected on Fedora.

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
  ;;
missing | corrupt)
  verify_optional_capability_report "AI profile" "$ai_state" "$ai_disposition"
  ;;
*)
  # Not selected, and no state file. The profile owns files outside its own
  # state, so an unselected machine is still asked whether any of them remain.
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
  ;;
esac

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

# The two profiles below record machine-local state their verification never
# read, so a standalone run described neither however this machine was
# installed (issue #344). Both are dispatched from the recorded selection and
# that state now; the flags stay, because inside the installer this verifier
# runs before the lifecycle record is committed, and there the flag is the only
# statement of selection there is.
containers_state="$(verify_optional_capability_state macos containers || true)"
containers_disposition="$(verify_optional_capability_disposition macos containers || true)"
if [[ "$verify_containers" == true && "$containers_disposition" == absent ]]; then
  containers_disposition=verify
fi

section "Optional Podman machine"
verify_optional_capability_report "Podman machine profile" "$containers_state" \
  "$containers_disposition" || true

if [[ "$containers_disposition" == verify || "$containers_disposition" == leftover ]]; then
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

tailscale_state="$(verify_optional_capability_state macos tailscale || true)"
tailscale_disposition="$(verify_optional_capability_disposition macos tailscale || true)"
if [[ "$verify_tailscale" == true && "$tailscale_disposition" == absent ]]; then
  tailscale_disposition=verify
fi

section "Optional Tailscale"
verify_optional_capability_report "Tailscale profile" "$tailscale_state" \
  "$tailscale_disposition" || true

if [[ "$tailscale_disposition" == verify || "$tailscale_disposition" == leftover ]]; then
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

# ---------------------------------------------------------------------------
# Optional dictation profile
#
# Ghost Pepper is the one macOS application this repository installs itself,
# from a pinned upstream disk image, because no Homebrew cask exists for it.
# That makes three things this verifier's business that Homebrew would
# otherwise answer: the installed build is the pinned one, it is the
# Developer-ID-signed and notarized build Gatekeeper accepts, and no second
# copy arrived through another provider.
#
# Selection is read from the recorded profile state as well as the flag, so a
# standalone run reaches the same verdict as one inside the installer, and an
# unselected machine is never failed for not having the application.
#
# The two privacy permissions this profile needs -- Microphone and
# Accessibility -- are deliberately interactive, and macOS keeps their grants
# in a SIP-protected TCC database no user process may read. There is no safe
# observable check, so they are reported as not observed rather than guessed
# at in either direction.
# ---------------------------------------------------------------------------

section "Optional dictation profile"

dictation_state="$(dictation_state_file)"
dictation_app="$(dictation_installed_app)"

dictation_disposition="$(verify_optional_capability_disposition macos dictation || true)"

# --dictation still forces the checks. Inside the installer this verifier runs
# before the lifecycle record is committed, so on that one path the flag is the
# only statement of selection there is.
if [[ "$verify_dictation" == true && "$dictation_disposition" == absent ]]; then
  dictation_disposition=verify
fi

if [[ "$dictation_disposition" != absent ]]; then
  # "missing" needs no report of its own: the state check at the end of this
  # body names the absent file, and the app checks in between are worth running
  # on a machine that asked for the profile whether or not its state survived.
  case "$dictation_disposition" in
  leftover | corrupt)
    verify_optional_capability_report "Dictation profile" "$dictation_state" \
      "$dictation_disposition"
    ;;
  esac

  if [[ -d "$dictation_app" ]]; then
    pass "Ghost Pepper is installed: $dictation_app"
  else
    fail "Ghost Pepper is missing: $dictation_app"
  fi

  dictation_version="$(dictation_installed_version "$dictation_app" 2>/dev/null || true)"
  if [[ "$dictation_version" == "$DICTATION_GHOST_PEPPER_VERSION" ]]; then
    pass "Ghost Pepper is at the pinned $DICTATION_GHOST_PEPPER_VERSION"
  else
    fail "Ghost Pepper reports ${dictation_version:-no version}, not the pinned" \
      "$DICTATION_GHOST_PEPPER_VERSION; rerun" \
      "platforms/macos/scripts/install-dictation.sh"
  fi

  check_arm64_file "Ghost Pepper" \
    "$dictation_app/Contents/MacOS/${DICTATION_GHOST_PEPPER_APP%.app}"

  # The pinned disk image is the declared provider. Homebrew publishes no
  # Ghost Pepper cask today; if one appears, a machine must not end up with
  # both, so the duplicate is named here rather than discovered later.
  dictation_casks="$("$(homebrew_path)" list --cask 2>/dev/null || true)"
  if grep -Fqi ghost-pepper <<<"$dictation_casks"; then
    fail "A Homebrew cask also provides Ghost Pepper; this profile owns the" \
      "pinned disk image, so remove one of the two copies"
  else
    pass "Ghost Pepper has no competing Homebrew cask"
  fi

  # Signature and notarization. This is the check that lets the profile coexist
  # with the repository's position that Gatekeeper and SIP stay enabled: the
  # application is accepted as it ships, with nothing removed or disabled to
  # make it run.
  if codesign --verify --strict "$dictation_app" >/dev/null 2>&1; then
    pass "Ghost Pepper's code signature is intact"
  else
    fail "Ghost Pepper's code signature does not verify: $dictation_app"
  fi

  dictation_signature="$(codesign --display --verbose=4 "$dictation_app" 2>&1 || true)"
  dictation_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$dictation_signature" | head -n 1)"
  if [[ "$dictation_team" == "$DICTATION_GHOST_PEPPER_TEAM_ID" ]]; then
    pass "Ghost Pepper is signed by the pinned Developer ID team $dictation_team"
  else
    fail "Ghost Pepper is signed by team ${dictation_team:-unknown}, not the" \
      "pinned $DICTATION_GHOST_PEPPER_TEAM_ID"
  fi

  if spctl --assess --type execute "$dictation_app" >/dev/null 2>&1; then
    pass "Gatekeeper accepts Ghost Pepper (Developer ID signed and notarized)"
  else
    fail "Gatekeeper does not accept Ghost Pepper; do not work around this by" \
      "disabling Gatekeeper or stripping the quarantine attribute"
  fi

  if [[ -f "$dictation_state" ]]; then
    dictation_recorded="$(profile_state_read "$dictation_state" version dictation 2>/dev/null || true)"
    if [[ "$dictation_recorded" == "$DICTATION_GHOST_PEPPER_VERSION" ]]; then
      pass "Recorded dictation state names the pinned $DICTATION_GHOST_PEPPER_VERSION"
    else
      fail "Recorded dictation state names ${dictation_recorded:-no version}," \
        "not the pinned $DICTATION_GHOST_PEPPER_VERSION: $dictation_state"
    fi
  else
    fail "Dictation profile state is missing: $dictation_state"
  fi

  not_observed "Microphone and Accessibility consent is interactive and kept in" \
    "a SIP-protected TCC database; confirm both for Ghost Pepper in System" \
    "Settings -> Privacy & Security"
elif [[ -e "$dictation_app" ]]; then
  # State left behind is "leftover" above, so what is left to discover here is
  # an application with no state beside it.
  fail "The dictation profile is not selected, but Ghost Pepper remains" \
    "($dictation_app); install the profile with --dictation, or remove the" \
    "application by hand"
else
  pass "Dictation profile is not installed (not selected)"
fi

finish_verification "macOS verification"
