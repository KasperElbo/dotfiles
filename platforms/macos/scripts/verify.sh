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

# file(1) is read with -b throughout this file. Without it the output begins
# with the path that was passed in, so the architecture words below are matched
# against the question as well as the answer: check_arm64_file's own caller
# hands it .../tools/netcoredbg/osx-arm64/netcoredbg, where "arm64" is in the
# path, and the check could not fail for an architecture reason -- an x86_64
# binary passed, and so did an HTML error page (issue #390, GAP-19). -b is
# supported by Apple's file(1).
check_arm64_file() {
  local name="$1"
  local path="$2"
  local architecture
  if [[ ! -e "$path" ]]; then
    fail "$name is missing: $path"
    return
  fi
  architecture="$(file -bL "$path" 2>/dev/null || true)"
  if [[ "$architecture" == *arm64* || "$architecture" == *universal* ]]; then
    pass "$name is arm64/universal: $path"
  else
    fail "$name does not report arm64 or universal architecture at $path:" \
      "${architecture:-file(1) reported nothing}"
  fi
}

# macos_managed_defaults <apply-defaults.sh>: the managed_defaults array's
# entries, one `domain|key|type|value` row per line, exactly as the installer
# declares them. macos_managed_screenshot_directory reads the one value that
# array leaves as a placeholder; $HOME is substituted by name rather than by
# evaluating the line, so a change to that assignment can add a directory but
# never a command.
macos_managed_defaults() {
  sed -n '/^managed_defaults=($/,/^)$/p' "$1" 2>/dev/null |
    sed -n "s/^[[:space:]]*'\(.*\)'[[:space:]]*$/\1/p"
}

macos_managed_screenshot_directory() {
  local declared
  declared="$(sed -n 's/^screenshot_directory="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1)"
  [[ -n "$declared" ]] || return 0
  printf '%s' "${declared//\$HOME/$HOME}"
}

# --- The one machine state this verifier can change --------------------------
#
# Verification is documented as read-only, and `podman run` on an image the
# machine does not have pulls it and keeps it, so a routine check left a
# container image in local storage (issue #372). What the smoke probe
# introduced is recorded here and undone again on every exit path, including a
# signal, rather than only on the line after the probe.
#
# The variable is empty whenever there is nothing to undo, so the handler is
# safe to run twice and safe to run when the probe was never reached. Removal
# is attempted only if the image is really there, so a machine with no usable
# podman produces no advice about an image it does not have.
MACOS_INTRODUCED_SMOKE_IMAGE=""

macos_restore_smoke_image() {
  local image="$MACOS_INTRODUCED_SMOKE_IMAGE"

  MACOS_INTRODUCED_SMOKE_IMAGE=""
  [[ -n "$image" ]] || return 0
  podman image inspect "$image" >/dev/null 2>&1 || return 0
  podman rmi --force "$image" >/dev/null 2>&1 ||
    warning "Verification pulled $image and could not remove it again;" \
      "remove it with 'podman rmi $image'"
}

# Restore, then re-raise so the caller still sees the interruption it sent.
macos_restore_smoke_image_on_signal() {
  macos_restore_smoke_image
  trap - INT TERM HUP EXIT
  kill -s "$1" "$$"
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
  verify_login_zsh -lic 'printf "\n__DOTFILES_VERIFY_PATH__%s\n" "$PATH"' 2>/dev/null |
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
  architecture="$(file -bL "$path" 2>/dev/null || true)"
  if [[ "$architecture" == *arm64* || "$architecture" == *universal* || "$architecture" == *script* || "$architecture" == *text* ]]; then
    pass "$name is native/universal: $path"
  else
    fail "$name does not report arm64 or universal architecture at $path:" \
      "${architecture:-file(1) reported nothing}"
  fi
done

# Every application bundle below is resolved through macos_applications_dir.
# A verifier that reads /Applications directly answers from the machine the
# tests happen to run on: the suite's fixture is ignored, the checks pass on a
# maintainer's own Mac and fail on a Linux runner, and which of the two a run
# reports has nothing to do with the tree under test.
applications_dir="$(macos_applications_dir)"
check_arm64_file "Ghostty" "$applications_dir/Ghostty.app/Contents/MacOS/ghostty"
check_arm64_file "AeroSpace" "$applications_dir/AeroSpace.app/Contents/MacOS/AeroSpace"
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
login_check="$(verify_login_zsh -lic 'printf "%s|%s|%s" "$(timeout --version 2>/dev/null | head -n1)" "$(command -v ls)" "$(starship --version >/dev/null && mise --version >/dev/null && printf ready)"' 2>/dev/null || true)"
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

# HOMEBREW_PREFIX is read by common/verify-ocaml.sh and scripts/bootstrap-macos.sh
# to find Homebrew rather than assume the Apple Silicon path. Both fall back to
# /opt/homebrew when it is unset, which is correct today and hides the variable
# never being exported at all, so assert the export itself: a fallback that is
# always taken proves nothing about the environment it claims to read.
# The expected value comes from Homebrew itself rather than from the file under
# test, so this asks whether the login shell agrees with the machine.
# shellcheck disable=SC2016 # Expansion belongs to the child Zsh process.
login_prefix="$(
  unset HOMEBREW_PREFIX
  verify_login_zsh -lic 'printf "%s" "${HOMEBREW_PREFIX:-}"' 2>/dev/null || true
)"
brew_prefix="$(brew --prefix 2>/dev/null || true)"
if [[ -z "$brew_prefix" ]]; then
  fail "Homebrew does not report a prefix, so HOMEBREW_PREFIX cannot be checked"
elif [[ "$login_prefix" == "$brew_prefix" ]]; then
  pass "Zsh login environment exports HOMEBREW_PREFIX: $login_prefix"
else
  fail "Zsh login environment exports HOMEBREW_PREFIX=${login_prefix:-unset}, but Homebrew reports $brew_prefix"
fi

# Apple's /bin/zsh and a deliberately selected Homebrew Zsh are both supported,
# so this asserts registration in /etc/shells rather than one exact path.
login_shell="$(macos_login_shell_for_user "$USER" || true)"
if macos_login_shell_is_compliant "$login_shell"; then
  pass "Account login shell is a registered Zsh: $login_shell"
else
  fail "Account login shell is not a registered Zsh: ${login_shell:-unknown}"
fi

# Every link is checked against the exact repository file Stow should have
# linked, not only against the package that owns it. A link redirected at
# another file inside the expected package resolved under the expected root and
# was reported green (issue #369).
#
# The third argument is written out per link, read off the package layout,
# rather than derived from the deployed path: deriving it would recompute the
# same $HOME-relative mapping Stow itself applied, so a wrong link and a wrong
# expectation would agree. Spelled out, this states what the file on disk is
# supposed to be.
section "Configuration links"
macos_stow="$DOTFILES_ROOT/platforms/macos/stow"
check_symlink "$HOME/.zshenv" "$DOTFILES_ROOT/zsh" \
  "$DOTFILES_ROOT/zsh/.zshenv"
check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" "$DOTFILES_ROOT/zsh" \
  "$DOTFILES_ROOT/zsh/.config/zsh/.zshrc"
check_symlink "$XDG_CONFIG_HOME/zsh/platform-env.zsh" "$macos_stow/zsh-platform" \
  "$macos_stow/zsh-platform/.config/zsh/platform-env.zsh"
check_symlink "$XDG_CONFIG_HOME/zsh/platform.zsh" "$macos_stow/zsh-platform" \
  "$macos_stow/zsh-platform/.config/zsh/platform.zsh"
check_symlink "$XDG_CONFIG_HOME/aerospace/aerospace.toml" "$macos_stow/aerospace" \
  "$macos_stow/aerospace/.config/aerospace/aerospace.toml"
check_symlink "$HOME/.local/bin/aerospace-workspace-grid" "$macos_stow/aerospace" \
  "$macos_stow/aerospace/.local/bin/aerospace-workspace-grid"
check_symlink "$XDG_CONFIG_HOME/git/config" "$DOTFILES_ROOT/git" \
  "$DOTFILES_ROOT/git/.config/git/config"
check_symlink "$XDG_CONFIG_HOME/mise/config.toml" "$DOTFILES_ROOT/mise" \
  "$DOTFILES_ROOT/mise/.config/mise/config.toml"
check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" "$DOTFILES_ROOT/nvim-lazyvim" \
  "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/init.lua"
check_symlink "$XDG_CONFIG_HOME/nvim/lua/plugins/macos.lua" "$macos_stow/nvim-macos" \
  "$macos_stow/nvim-macos/.config/nvim/lua/plugins/macos.lua"
check_symlink "$XDG_CONFIG_HOME/ghostty/macos.conf" "$macos_stow/ghostty-macos" \
  "$macos_stow/ghostty-macos/.config/ghostty/macos.conf"

# verifies: terminal -- Ghostty is the macOS terminal, installed from the
# Brewfile with the baseline.
ghostty_binary="$(macos_applications_dir)/Ghostty.app/Contents/MacOS/ghostty"
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
if [[ -d "$(macos_applications_dir)/AeroSpace.app" ]]; then pass "AeroSpace application is installed"; else fail "AeroSpace application is missing"; fi

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
  "$macos_stow/theme-hooks" \
  "$macos_stow/theme-hooks/.config/dotfiles/theme-hooks.d/macos.sh"
# theme-assets is one shared package at the top of the checkout rather than a
# macOS copy, which is why its root is not under $macos_stow. Each flavour has
# its own image, so the expected source carries the flavour too: without it a
# link to catppuccin-latte.webp satisfied the mocha check.
for flavour in latte frappe macchiato mocha; do
  check_symlink "$XDG_DATA_HOME/wallpapers/catppuccin-${flavour}.webp" \
    "$DOTFILES_ROOT/theme-assets" \
    "$DOTFILES_ROOT/theme-assets/.local/share/wallpapers/catppuccin-${flavour}.webp"
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
    verify_login_zsh -lic 'printf "\n__DOTFILES_VERIFY_THEME__%s|%s\n" "${STARSHIP_CONFIG:-}" "${BAT_THEME:-}"' \
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
  architecture="$(file -bL "$canonical" 2>/dev/null || true)"
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
    if verify_login_zsh -lic 'command -v "$1" >/dev/null' _ "$name" >/dev/null 2>&1; then
      pass "Fresh Zsh login resolves $name"
    else
      fail "Fresh Zsh login does not resolve $name"
    fi
  done
  if verify_login_zsh -lic 'claude --version >/dev/null' >/dev/null 2>&1; then
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
  # The expected set is read out of the installer rather than restated. It used
  # to be a hand-copied five-entry subset of the thirteen keys apply-defaults.sh
  # writes, so the Dock orientation and tile size, the Finder hidden-file and
  # status-bar settings, and both the screenshot and key-repeat pairs were named
  # by this section and by the installer's own plan step -- "Apply reversible
  # Dock, Finder, screenshot, keyboard, and Mission Control defaults" -- and read
  # by nothing (issue #396, GAP-22). Deriving it is the discipline
  # verify_catppuccin_tmux_pin already uses for the tmux theme pin.
  managed_defaults_source="$DOTFILES_ROOT/platforms/macos/scripts/apply-defaults.sh"
  mapfile -t expected_defaults < <(macos_managed_defaults "$managed_defaults_source")
  screenshot_directory="$(macos_managed_screenshot_directory "$managed_defaults_source")"
  if ((${#expected_defaults[@]} == 0)) || [[ -z "$screenshot_directory" ]]; then
    fail "Could not read the managed defaults set from $managed_defaults_source"
  fi
  for item in "${expected_defaults[@]}"; do
    IFS='|' read -r domain key value_type value <<<"$item"
    # `defaults read` answers a boolean as 1 or 0 whatever spelling was written,
    # and the installer substitutes the screenshot directory into its own
    # placeholder, so both are translated here the same way it translates them.
    if [[ "$value" == __SCREENSHOT_DIRECTORY__ ]]; then
      expected="$screenshot_directory"
    elif [[ "$value_type" == bool ]]; then
      if [[ "$value" == true ]]; then expected=1; else expected=0; fi
    else
      expected="$value"
    fi
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
  # An image already on this machine is run with --pull=never, so the probe
  # touches neither the network nor local image storage and the operator's tag
  # keeps naming the image it named before. One this machine does not have is
  # pulled, and then removed again. Nothing here reads back what this block
  # just did -- a check that asserts its own side effect is the shape #398 is
  # about -- so tests/test-macos-verification.sh asserts the restore from
  # outside, against the image store itself.
  # network-source: smoke-image-alpine
  smoke_image="docker.io/library/alpine:latest"
  if podman image inspect "$smoke_image" >/dev/null 2>&1; then
    smoke_pull_policy=never
  else
    smoke_pull_policy=missing
    MACOS_INTRODUCED_SMOKE_IMAGE="$smoke_image"
    trap 'macos_restore_smoke_image_on_signal INT' INT
    trap 'macos_restore_smoke_image_on_signal TERM' TERM
    trap 'macos_restore_smoke_image_on_signal HUP' HUP
    trap macos_restore_smoke_image EXIT
  fi
  machine_arch="$(
    podman run --rm --pull="$smoke_pull_policy" "$smoke_image" uname -m 2>/dev/null || true
  )"
  macos_restore_smoke_image
  trap - INT TERM HUP EXIT
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
  tailscale_app="$(macos_applications_dir)/Tailscale.app"
  if [[ -d "$tailscale_app" ]]; then
    pass "Tailscale application is installed"
  else
    fail "Tailscale application is missing"
  fi

  tailscale_cli=""
  if [[ -x /usr/local/bin/tailscale ]]; then
    tailscale_cli=/usr/local/bin/tailscale
  elif [[ -x "$tailscale_app/Contents/MacOS/Tailscale" ]]; then
    tailscale_cli="$tailscale_app/Contents/MacOS/Tailscale"
  fi

  if [[ -n "$tailscale_cli" ]]; then
    # Both calls go through the bounded probe in platforms/macos/lib/macos.sh.
    # The status is taken on the failing branch of the assignment rather than
    # read after an `if`, which would report the `if` itself.
    version_output=""
    version_status=0
    version_output="$(macos_tailscale_probe "$tailscale_cli" version 2>&1)" ||
      version_status=$?
    if ((version_status == 0)); then
      pass "tailscale version: $(printf '%s' "$version_output" | head -n1)"
    elif macos_tailscale_probe_timed_out "$version_status"; then
      warning "'tailscale version' did not answer within ${DOTFILES_TAILSCALE_PROBE_TIMEOUT}s, so the CLI was not read; the application may be waiting on a permission prompt"
    else
      fail "tailscale version failed"
    fi

    status_json=""
    status_probe=0
    status_json="$(macos_tailscale_probe "$tailscale_cli" status --json 2>/dev/null)" ||
      status_probe=$?
    if ((status_probe == 0)); then
      backend_state="$(printf '%s' "$status_json" | jq -r '.BackendState // "unknown"' 2>/dev/null)"
      case "$backend_state" in
      Running) pass "tailscale status: Running (connected to a tailnet)" ;;
      NeedsLogin | NoState | Stopped | Starting | NeedsMachineAuth)
        pass "tailscale status: $backend_state (installed but not logged in)"
        ;;
      *) warning "tailscale status reported an unrecognized BackendState: ${backend_state:-empty}" ;;
      esac
    elif macos_tailscale_probe_timed_out "$status_probe"; then
      warning "'tailscale status --json' did not answer within ${DOTFILES_TAILSCALE_PROBE_TIMEOUT}s; the application may be waiting on a permission prompt"
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
  # The status is taken on the failing branch of the assignment, the way the
  # Tailscale probes above do it. Discarding it made a Homebrew that could not
  # answer at all indistinguishable from one that answered "no cask": grep on
  # the empty string does not match, so absence of evidence was reported as
  # evidence of absence, and this was the one check in the section that did not
  # fail closed (issue #396, GAP-24).
  dictation_casks=""
  dictation_cask_status=0
  dictation_casks="$("$(homebrew_path)" list --cask 2>/dev/null)" ||
    dictation_cask_status=$?
  if ((dictation_cask_status != 0)); then
    not_observed "Homebrew did not list its casks (exit $dictation_cask_status)," \
      "so a competing Ghost Pepper cask could not be ruled out"
  elif grep -Fqi ghost-pepper <<<"$dictation_casks"; then
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

  # Notarization, and why this asks spctl for an *install* assessment.
  #
  # `spctl --assess --type execute` is the obvious call to make here, and it is
  # the one this check used to make. It can never pass for this bundle. Ghost
  # Pepper's Info.plist carries no CFBundlePackageType key, and that key is
  # what the execute assessment reads to decide whether a bundle is an
  # application at all, so spctl answers
  #
  #   GhostPepper.app: rejected (the code is valid but does not seem to be an app)
  #
  # and exits 3. That is a refusal to classify the bundle rather than a
  # security verdict -- spctl states in the same line that the code is valid --
  # but 3 is also the status for a genuine denial, so reading the status alone
  # reported a notarization failure on a correctly installed machine, on every
  # machine, every time. Confirmed on a clean macOS 26 runner against the
  # pinned artifact and on a workstation where the application runs.
  #
  # `--type install` assesses the same bundle without first asking what kind of
  # bundle it is, and answers with Gatekeeper's own verdict and source:
  #
  #   GhostPepper.app: accepted
  #   source=Notarized Developer ID
  #
  # That source string is the assertion, not the exit status. A status of 0
  # would also be satisfied by `source=Developer ID`, which is a signed build
  # Apple never notarized, so passing on the status would accept exactly the
  # artifact this check exists to reject.
  #
  # Two things this deliberately does not assert. The bundle carries no
  # stapled notarization ticket: upstream staples the ticket to the disk image,
  # so `xcrun stapler validate` on the installed application always reports
  # none, and asserting one would fail on a correct install. And the download
  # is fetched with curl, which sets no quarantine attribute, so there is no
  # Gatekeeper first-launch assessment to observe either.
  #
  # The probe is bounded because an assessment may reach Apple's notarization
  # service; see the comment above macos_bounded_probe.
  dictation_assess=""
  dictation_assess_status=0
  dictation_assess="$(macos_bounded_probe "$DOTFILES_DICTATION_ASSESS_TIMEOUT" \
    spctl --assess --type install --verbose=4 "$dictation_app" 2>&1)" ||
    dictation_assess_status=$?
  # No pipe into head: with pipefail a producer killed by SIGPIPE fails the
  # pipeline exactly when the match is found.
  dictation_assess_source="$(sed -n '/^source=/{s/^source=//p;q;}' <<<"$dictation_assess")"
  dictation_assess_first="${dictation_assess%%$'\n'*}"
  if macos_probe_timed_out "$dictation_assess_status"; then
    warning "The Gatekeeper assessment of Ghost Pepper did not answer within ${DOTFILES_DICTATION_ASSESS_TIMEOUT}s, so its notarization was not read; the assessment may be waiting on Apple's notarization service"
  elif ((dictation_assess_status == 0)) &&
    [[ "$dictation_assess_source" == "Notarized Developer ID" ]]; then
    pass "Gatekeeper accepts Ghost Pepper (source=$dictation_assess_source)"
  elif ((dictation_assess_status == 0)); then
    fail "Gatekeeper accepts Ghost Pepper, but not as a notarized build" \
      "(source=${dictation_assess_source:-none}); the pinned release is" \
      "notarized, so this is not the reviewed artifact"
  elif ((dictation_assess_status == 3)); then
    fail "Gatekeeper does not accept Ghost Pepper; do not work around this by" \
      "disabling Gatekeeper or stripping the quarantine attribute." \
      "spctl said: ${dictation_assess_first:-nothing}"
  else
    fail "The Gatekeeper assessment of Ghost Pepper could not be made; spctl" \
      "exited $dictation_assess_status saying:" \
      "${dictation_assess_first:-nothing}"
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
