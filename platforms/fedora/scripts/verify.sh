#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"
# shellcheck source=../lib/secure-boot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/secure-boot.sh"
# shellcheck source=../lib/hardening.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hardening.sh"
# shellcheck source=../../../common/lib/install-lifecycle.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/install-lifecycle.sh"
# shellcheck source=../../../common/lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/tool-floors.sh"

verify_reset

# ---------------------------------------------------------------------------
# Core commands
# ---------------------------------------------------------------------------

section "Core commands"

# Every command here is run, not only found on PATH: a binary that resolves but
# cannot start is a broken install. common/lib/verify.sh owns the probe each
# command answers. curl, gpg and jq are declared by the base package set, so
# they are checked here unconditionally rather than only by the optional
# sections that happen to use them.
commands=(
  bat
  curl
  delta
  eza
  fd
  fzf
  gh
  git
  ghostty
  gpg
  jq
  mise
  nvim
  rg
  scp
  sftp
  shellcheck
  sqlite3
  ssh
  starship
  stow
  tmux
  wl-copy
  wl-paste
  zoxide
  zsh
)

for cmd in "${commands[@]}"; do
  check_command "$cmd" --probe
done

# ---------------------------------------------------------------------------
# SFTP client baseline (always checked; command-line SFTP is a base
# capability, not an optional profile)
# ---------------------------------------------------------------------------

section "SFTP client baseline"

if rpm -q openssh-clients >/dev/null 2>&1; then
  pass "openssh-clients: $(rpm -q openssh-clients)"
else
  fail "openssh-clients package is not installed"
fi

# "a command called sftp exists" is not the claim this repository makes: the
# claim is that the SFTP client comes from Fedora's own openssh-clients
# package, so there is never a second SSH implementation to manage. Ask RPM
# which package owns the binary that actually resolves, rather than trusting
# whatever happens to be first on PATH.
for cmd in sftp scp ssh; do
  resolved="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    fail "$cmd not found; openssh-clients should provide it"
    continue
  fi
  # RPM records the real path, and Fedora's /usr/sbin is a symlink to
  # /usr/bin, so PATH order alone decides whether "command -v" hands back a
  # spelling the package database can match. Canonicalize first, or the query
  # reports "no owning package" for a perfectly correct installation.
  canonical="$(verify_canonical_existing_path "$resolved" 2>/dev/null || true)"
  owner="$(rpm -qf --queryformat '%{NAME}' "${canonical:-$resolved}" \
    2>/dev/null || true)"
  if [[ "$owner" == openssh-clients ]]; then
    pass "$cmd is provided by openssh-clients: ${canonical:-$resolved}"
  else
    fail "$cmd resolves to ${canonical:-$resolved}, owned by" \
      "${owner:-no RPM package}; expected Fedora's openssh-clients"
  fi
done

ssh_version="$(ssh -V 2>&1 || true)"
if [[ "$ssh_version" == *OpenSSH* ]]; then
  pass "ssh -V: $ssh_version"
else
  fail "ssh -V did not report an OpenSSH client: ${ssh_version:-no output}"
fi

# The KDE capability owns kio-extras and the Catppuccin KDE themes. A machine
# installed with --no-kde owns neither, so requiring them there would fail a
# correct installation just because Plasma happens to be present (issue #148).
kde_selection_status=0
install_lifecycle_capability_selected kde || kde_selection_status=$?

# Selection, not just the artifact. Gating the checks on plasmashell alone let
# the thing that was supposed to be verified decide whether it was verified: a
# machine that recorded --kde and never got Plasma was described by no check at
# all and scored the same as one that never asked for it (issue #394, GAP-09).
# The artifact arm stays so an unselected machine's leftovers are still found.
if ((kde_selection_status == 1)); then
  section "KDE integration"
  pass "KDE integration is not selected; its assets are not expected"
elif ((kde_selection_status == 0)) || command_exists plasmashell; then
  section "KDE Dolphin/KIO SFTP integration"

  check_command dolphin

  if rpm -q kio-extras >/dev/null 2>&1; then
    pass "kio-extras: $(rpm -q kio-extras)"
  else
    fail "kio-extras package is not installed; sftp:// locations will not open in Dolphin"
  fi
fi

# ---------------------------------------------------------------------------
# Fedora security baseline (always checked, independent of --hardening)
# ---------------------------------------------------------------------------

section "Fedora security baseline"

case "$(selinux_mode)" in
enforcing)
  pass "SELinux is enforcing"
  ;;
unavailable)
  warning "SELinux is not available on this kernel (e.g. inside a container)"
  ;;
unknown)
  warning "Could not determine SELinux mode (getenforce not found)"
  ;;
*)
  fail "SELinux is not enforcing"
  ;;
esac

check_system_service_enabled_and_active firewalld.service

case "$(secure_boot_state)" in
enabled)
  pass "Secure Boot is enabled"
  ;;
disabled)
  warning "Secure Boot is disabled (informational; not required on every machine)"
  ;;
*)
  warning "Secure Boot state could not be determined"
  ;;
esac

# ---------------------------------------------------------------------------
# Terra trust root (always checked: Terra supplies base packages, and the
# installer verifies its signing key only once)
# ---------------------------------------------------------------------------

section "Terra trust root"

verify_terra_trust_root

# ---------------------------------------------------------------------------
# RPM Fusion trust root (checked when the repositories are present: the
# desktop-tools installer adds them once and never looks at them again)
# ---------------------------------------------------------------------------

section "RPM Fusion trust root"

verify_rpm_fusion_trust_root

# ---------------------------------------------------------------------------
# Login shell
# ---------------------------------------------------------------------------

section "Login shell"

current_user="$(id -un)"
login_shell="$(login_shell_for_user "$current_user" 2>/dev/null || true)"
zsh_path="$(resolve_zsh_path 2>/dev/null || true)"

if shell_paths_match "$login_shell" "$zsh_path"; then
  pass "Zsh is the default login shell"
else
  fail "Default login shell is not Zsh: ${login_shell:-unknown}"
fi

# ---------------------------------------------------------------------------
# Stow-managed configuration
# ---------------------------------------------------------------------------

section "Stow links"

check_symlink "$HOME/.zshenv" \
  "$DOTFILES_ROOT/zsh/" \
  "$DOTFILES_ROOT/zsh/.zshenv"

check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" \
  "$DOTFILES_ROOT/zsh/" \
  "$DOTFILES_ROOT/zsh/.config/zsh/.zshrc"

# verifies: terminal -- Ghostty is the workstation terminal, installed with the
# baseline and configured by the portable ghostty Stow package.
check_symlink "$XDG_CONFIG_HOME/ghostty/config" \
  "$DOTFILES_ROOT/ghostty/" \
  "$DOTFILES_ROOT/ghostty/.config/ghostty/config"

check_symlink "$XDG_CONFIG_HOME/git/config" \
  "$DOTFILES_ROOT/git/" \
  "$DOTFILES_ROOT/git/.config/git/config"

check_symlink "$XDG_CONFIG_HOME/lazygit/config.yml" \
  "$DOTFILES_ROOT/lazygit/" \
  "$DOTFILES_ROOT/lazygit/.config/lazygit/config.yml"

check_symlink "$XDG_CONFIG_HOME/mise/config.toml" \
  "$DOTFILES_ROOT/mise/" \
  "$DOTFILES_ROOT/mise/.config/mise/config.toml"

check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" \
  "$DOTFILES_ROOT/nvim-lazyvim/" \
  "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/init.lua"

check_symlink "$HOME/.tmux.conf" \
  "$DOTFILES_ROOT/tmux/" \
  "$DOTFILES_ROOT/tmux/.tmux.conf"

check_symlink "$HOME/.local/bin/theme" \
  "$DOTFILES_ROOT/bin/" \
  "$DOTFILES_ROOT/bin/.local/bin/theme"

for flavour in latte frappe macchiato mocha; do
  check_symlink \
    "$XDG_DATA_HOME/wallpapers/catppuccin-${flavour}.webp" \
    "$DOTFILES_ROOT/theme-assets/" \
    "$DOTFILES_ROOT/theme-assets/.local/share/wallpapers/catppuccin-${flavour}.webp"
  check_symlink \
    "$XDG_DATA_HOME/wallpapers/catppuccin-${flavour}-lock.webp" \
    "$DOTFILES_ROOT/theme-assets/" \
    "$DOTFILES_ROOT/theme-assets/.local/share/wallpapers/catppuccin-${flavour}-lock.webp"
done

# ---------------------------------------------------------------------------
# Machine-local theme
# ---------------------------------------------------------------------------

section "Theme"

theme_file="$XDG_CONFIG_HOME/dotfiles/theme"

if [[ ! -f "$theme_file" ]]; then
  fail "Theme state file missing: $theme_file"
  current_theme=""
else
  current_theme="$(tr -d '[:space:]' <"$theme_file")"

  case "$current_theme" in
  latte | frappe | macchiato | mocha)
    pass "Current Catppuccin flavour: $current_theme"
    ;;
  *)
    fail "Invalid Catppuccin flavour: $current_theme"
    ;;
  esac
fi

if [[ -n "$current_theme" ]]; then
  expected_derived_files=(
    "$XDG_CONFIG_HOME/dotfiles/ghostty.conf"
    "$XDG_CONFIG_HOME/dotfiles/git-theme"
    "$XDG_CONFIG_HOME/dotfiles/tmux-theme.conf"
    "$XDG_CONFIG_HOME/starship/catppuccin-${current_theme}.toml"
    "$XDG_CONFIG_HOME/fzf/themes/catppuccin-fzf-${current_theme}.sh"
    "$XDG_CONFIG_HOME/lazygit/themes/catppuccin-${current_theme}-mauve.yml"
    "$XDG_CONFIG_HOME/ghostty/themes/catppuccin-${current_theme}.conf"
  )

  for theme_path in "${expected_derived_files[@]}"; do
    if [[ -e "$theme_path" ]]; then
      pass "Theme asset: $theme_path"
    else
      fail "Theme asset missing: $theme_path"
    fi
  done

  if grep -q \
    "theme = catppuccin-${current_theme}.conf" \
    "$XDG_CONFIG_HOME/dotfiles/ghostty.conf" 2>/dev/null; then
    pass "Ghostty local theme override matches"
  else
    fail "Ghostty local theme override does not match $current_theme"
  fi

  if grep -q \
    "features = catppuccin-${current_theme}" \
    "$XDG_CONFIG_HOME/dotfiles/git-theme" 2>/dev/null; then
    pass "Delta local theme override matches"
  else
    fail "Delta local theme override does not match $current_theme"
  fi

  if grep -q \
    "@catppuccin_flavor \"${current_theme}\"" \
    "$XDG_CONFIG_HOME/dotfiles/tmux-theme.conf" 2>/dev/null; then
    pass "tmux local theme override matches"
  else
    fail "tmux local theme override does not match $current_theme"
  fi

  # Check exactly what the installed capability owns: the Fedora theme hook
  # applies a KDE global theme by name, so that name must exist on a machine
  # that selected KDE, and must not be expected on one that did not.
  case "$current_theme" in
  latte) kde_global_theme="Catppuccin-Latte-Mauve" ;;
  frappe) kde_global_theme="Catppuccin-Frappe-Mauve" ;;
  macchiato) kde_global_theme="Catppuccin-Macchiato-Mauve" ;;
  mocha) kde_global_theme="Catppuccin-Mocha-Mauve" ;;
  esac
  kde_theme_path="$XDG_DATA_HOME/plasma/look-and-feel/$kde_global_theme"

  if ((kde_selection_status == 0)); then
    if [[ -d "$kde_theme_path" ]]; then
      pass "Catppuccin KDE global theme installed: $kde_global_theme"
    else
      fail "KDE integration is selected but its global theme is missing: $kde_theme_path"
    fi
  elif ((kde_selection_status == 1)) && [[ -d "$kde_theme_path" ]]; then
    warning "KDE integration is not selected, but $kde_theme_path exists;" \
      "the theme command will not apply it"
  fi
fi

# ---------------------------------------------------------------------------
# Optional Sway session
# ---------------------------------------------------------------------------

# The same reasoning as the KDE gate above: a machine that recorded --sway and
# whose stow step never ran has no sway/config, and the artifact test alone
# therefore skipped the whole section rather than reporting the 37 checks that
# would have named what is missing (issue #394, GAP-09).
sway_selection_status=0
install_lifecycle_capability_selected sway || sway_selection_status=$?

if ((sway_selection_status == 0)) ||
  [[ -e "$XDG_CONFIG_HOME/sway/config" || -L "$XDG_CONFIG_HOME/sway/config" ]]; then
  section "Sway session"

  sway_commands=(
    blueman-manager
    brightnessctl
    cliphist
    dex-autostart
    fuzzel
    grim
    jq
    /usr/libexec/lxqt-policykit-agent
    mako
    nm-connection-editor
    pavucontrol
    playerctl
    slurp
    sway
    swaybg
    swayidle
    swaylock
    /usr/libexec/sway-systemd/session.sh
    swappy
    sway-session-start
    waybar
    /usr/local/bin/dotfiles-sway
  )

  for cmd in "${sway_commands[@]}"; do
    check_command "$cmd"
  done

  if [[ -f /usr/share/wayland-sessions/dotfiles-sway.desktop ]]; then
    pass "Dotfiles Sway login session installed"
  else
    fail "Dotfiles Sway login session missing"
  fi

  check_symlink "$XDG_CONFIG_HOME/sway/config" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/.config/sway/config"
  check_symlink \
    "$XDG_CONFIG_HOME/xdg-desktop-portal/sway-portals.conf" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/.config/xdg-desktop-portal/sway-portals.conf"
  check_symlink "$XDG_CONFIG_HOME/waybar/config.jsonc" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/.config/waybar/config.jsonc"
  check_symlink "$XDG_CONFIG_HOME/waybar/style.css" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/.config/waybar/style.css"
  check_symlink "$HOME/.local/bin/sway-workspace-grid" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/.local/bin/sway-workspace-grid"
  check_symlink "$HOME/.local/bin/sway-output-cycle" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/.local/bin/sway-output-cycle"
  check_symlink "$HOME/.local/bin/sway-session-start" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/.local/bin/sway-session-start"

  local_sway="$XDG_CONFIG_HOME/sway/local.conf"
  if [[ -f "$local_sway" && ! -L "$local_sway" ]]; then
    pass "Machine-local Sway output override: $local_sway"
  else
    fail "Machine-local Sway output override missing or linked: $local_sway"
  fi

  if git -C "$DOTFILES_ROOT" ls-files --error-unmatch -- \
    "platforms/fedora/stow/sway/.config/sway/local.conf" >/dev/null 2>&1; then
    fail "Machine-local Sway output override is tracked"
  else
    pass "Machine-local Sway output override is not tracked"
  fi

  sway_theme_files=(
    "$XDG_CONFIG_HOME/dotfiles/sway-theme.conf"
    "$XDG_CONFIG_HOME/dotfiles/waybar-theme.css"
    "$XDG_CONFIG_HOME/dotfiles/fuzzel.ini"
    "$XDG_CONFIG_HOME/dotfiles/mako.conf"
    "$XDG_CONFIG_HOME/dotfiles/swaylock.conf"
  )

  for theme_path in "${sway_theme_files[@]}"; do
    if [[ -f "$theme_path" ]]; then
      pass "Sway theme state: $theme_path"
    else
      fail "Sway theme state missing: $theme_path"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Git identities
# ---------------------------------------------------------------------------

section "Git local configuration"

for name in local drdk; do
  file="$XDG_CONFIG_HOME/git/$name"
  repo_relative_path="git/.config/git/$name"
  repo_file="$DOTFILES_ROOT/$repo_relative_path"

  if git -C "$DOTFILES_ROOT" ls-files --error-unmatch -- \
    "$repo_relative_path" >/dev/null 2>&1; then
    fail "Machine-local Git config is tracked: $repo_relative_path"
  else
    pass "Machine-local Git config is not tracked: $repo_relative_path"
  fi

  if [[ -e "$repo_file" || -L "$repo_file" ]]; then
    fail "Machine-local Git config exists inside the Stow package: $repo_file"
  else
    pass "Machine-local Git config is outside the Stow package: $name"
  fi

  if [[ -L "$file" ]] &&
    [[ "$(realpath -m "$file")" == "$repo_file" ]]; then
    fail "Local Git config still links into the dotfiles repo: $file"
  elif [[ -f "$file" ]]; then
    pass "Local Git config exists: $file"
  else
    warning "Local Git config missing: $file"
  fi
done

if git config --get user.email >/dev/null 2>&1; then
  pass "Default Git identity configured"
else
  warning "Default Git identity is not configured"
fi

# ---------------------------------------------------------------------------
# mise
# ---------------------------------------------------------------------------

section "mise"

mise_command="$(resolve_mise_command 2>/dev/null || true)"
if [[ -n "$mise_command" ]]; then
  # Verify the PATH a fresh Zsh login will receive, rather than the
  # possibly stale Bash PATH used to invoke this verifier.
  VERIFY_CONFIGURED_LOGIN_PATH="$(
    zsh -lic 'printf "%s\\n" "$PATH"' 2>/dev/null || true
  )"
  VERIFY_CALLER_PATH="$PATH"
  VERIFY_MISE_COMMAND="$mise_command"
  establish_user_tool_environment

  mise_tools=(
    dotnet
    node
    python
    uv
    lazygit
    ast-grep
    tree-sitter
    neovim-node-host
    dotnet-easydotnet
  )

  check_mise_context

  # run_mise, not a bare invocation: common/lib/common.sh's contract is that
  # every install, resolution and verification call goes through it, so a
  # caller's project mise.toml can never reach a global bootstrap. This was the
  # one mise call in any verifier that did not, so it answered for whatever
  # directory the operator happened to run the verifier from, and an unrelated
  # unparseable project config failed a machine whose global config is perfect
  # (issue #396, GAP-12). It runs after check_mise_context so the precondition
  # run_mise relies on is reported before it is relied on.
  if run_mise "$mise_command" ls >/dev/null 2>&1; then
    pass "mise configuration loads successfully"
  else
    fail "mise could not load configured tools"
  fi

  for cmd in "${mise_tools[@]}"; do
    check_mise_owned "$cmd"
  done

  case "$(uname -m)" in
  aarch64 | arm64) check_easy_dotnet_debugger linux-arm64 ;;
  x86_64 | amd64) check_easy_dotnet_debugger linux-x64 ;;
  *) fail "Unsupported .NET debugger architecture: $(uname -m)" ;;
  esac
else
  fail "mise not found"
fi

# ---------------------------------------------------------------------------
# Neovim / Mason
# ---------------------------------------------------------------------------

section "Neovim tooling"

check_mason_inventory "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"

# The plugin tree is proved from the deployed lock file before Neovim is
# started, because the start cannot prove it: the configuration installs
# whatever the profile names and does not find, so a start that reached the end
# only showed that anything missing had since been fetched. The lock file read
# is the stowed copy under XDG_CONFIG_HOME, not the repository's, so it
# verifies what was actually deployed.
check_lazy_plugin_state "$XDG_CONFIG_HOME/nvim/lazy-lock.json"

# The floor comes from config/tool-floors.tsv like every other enforcer of it,
# and Neovim itself asserts it, which also proves it starts. The shared helper
# owns the bound and the verify-mode environment.
check_neovim_starts Neovim "$(tool_floor nvim)"

# ---------------------------------------------------------------------------
# Optional OCaml profile
# ---------------------------------------------------------------------------

# The shared verifier decides for itself whether the profile was selected, so
# running it unconditionally is what makes "selected but never installed" fail
# instead of silently skipping.

section "OCaml profile"

if DOTFILES_NATIVE_PREFIX=/usr \
  DOTFILES_NATIVE_OWNER=opam \
  DOTFILES_NATIVE_OWNER_QUERY='rpm -qf --queryformat %{NAME}' \
  "$DOTFILES_ROOT/common/verify-ocaml.sh"; then
  pass "Optional OCaml profile"
else
  fail "Optional OCaml profile verification failed"
fi

# ---------------------------------------------------------------------------
# Optional LaTeX toolchain
#
# verifies: latex
#
# The latex capability keeps no profile state of its own (state=- in
# config/capabilities.tsv is deliberate), so the recorded installation
# selection is the only evidence that this machine asked for TeX. Reading it
# here, rather than taking a --latex flag from the installer the way the WSL
# verifier does, keeps the verdict the same whether platforms/fedora/install.sh
# runs this script as its final step or somebody runs it by hand months later.
#
# Compiling a document is deliberately not attempted: the disposable
# multi-file build belongs to scripts/test-dev-workflows.sh --latex.
# ---------------------------------------------------------------------------

section "LaTeX toolchain"

latex_selection_status=0
install_lifecycle_capability_selected latex || latex_selection_status=$?

if ((latex_selection_status == 0)); then
  # What platforms/fedora/scripts/install-latex.sh must put on PATH:
  # texlive-scheme-medium provides latex and the three engines, and latexmk,
  # biber and texlive-latexindent provide the rest. A missing command is a
  # broken installation of a capability this machine selected, not a warning.
  for latex_command in biber latex latexindent latexmk lualatex pdflatex xelatex; do
    check_command "$latex_command"
  done

  if command_exists latexmk; then
    latexmk_version="$(latexmk -v 2>/dev/null | head -n 1 || true)"
    if [[ -n "$latexmk_version" ]]; then
      pass "latexmk version: $latexmk_version"
    else
      warning "latexmk is installed but did not report a version"
    fi
  fi
else
  # A machine with no readable installation record is treated like one that
  # did not select the capability: scripts/doctor.sh already reports a missing
  # lifecycle record, and this verifier must not invent a selection.
  pass "LaTeX toolchain is not selected; its commands are not applicable"

  if command_exists latexmk; then
    warning "latexmk is on PATH at $(command -v latexmk) but the LaTeX" \
      "capability is not selected; TeX here is not owned by these dotfiles"
  fi
fi

# ---------------------------------------------------------------------------
# Catppuccin tmux
# ---------------------------------------------------------------------------

section "Catppuccin tmux"

# The pinned plugin checkout at $XDG_DATA_HOME/tmux/plugins/catppuccin.
check_catppuccin_tmux

# ---------------------------------------------------------------------------
# Optional machine hardware
# ---------------------------------------------------------------------------

verify_optional_capability "ASUS hardware" fedora hardware \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-asus-hardware.sh"

# ---------------------------------------------------------------------------
# Optional VM host
# ---------------------------------------------------------------------------

verify_optional_capability "VM host" fedora vm-host \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh"

# ---------------------------------------------------------------------------
# Optional VM guest
# ---------------------------------------------------------------------------

verify_optional_capability "VM guest" fedora vm-guest \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-guest.sh"

# ---------------------------------------------------------------------------
# Optional security-hardening profile
# ---------------------------------------------------------------------------

verify_optional_capability "Security hardening" fedora hardening \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-hardening.sh"

# ---------------------------------------------------------------------------
# Optional desktop tools
# ---------------------------------------------------------------------------

verify_optional_capability "Desktop tools" fedora desktop-tools \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-desktop-tools.sh"

# ---------------------------------------------------------------------------
# Optional dictation profile
# ---------------------------------------------------------------------------

verify_optional_capability "Dictation" fedora dictation \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-dictation.sh"

# ---------------------------------------------------------------------------
# Optional containers (Podman) profile
# ---------------------------------------------------------------------------

verify_optional_capability "Containers (Podman)" fedora containers \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-containers.sh" \
  --skip-smoke-test

# ---------------------------------------------------------------------------
# Optional Tailscale networking profile
# ---------------------------------------------------------------------------

verify_optional_capability "Tailscale" fedora tailscale \
  "$DOTFILES_ROOT/platforms/fedora/scripts/verify-tailscale.sh"

# ---------------------------------------------------------------------------
# Optional AI-assisted development profile
# ---------------------------------------------------------------------------

ai_state="$(verify_optional_capability_state fedora ai || true)"
ai_disposition="$(verify_optional_capability_disposition fedora ai || true)"

section "AI-assisted development profile"

case "$ai_disposition" in
verify | leftover)
  verify_optional_capability_report "AI profile" "$ai_state" "$ai_disposition"

  if "$DOTFILES_ROOT/common/verify-ai.sh"; then
    pass "AI profile verification completed"
  else
    fail "AI profile verification failed"
  fi
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

# ---------------------------------------------------------------------------
# Repository hygiene
# ---------------------------------------------------------------------------

section "Repository hygiene"

nested_git="$(
  find "$DOTFILES_ROOT" \
    -path "$DOTFILES_ROOT/.git" -prune -o \
    -type d -name .git -print
)"

if [[ -z "$nested_git" ]]; then
  pass "No nested Git repositories"
else
  fail "Nested Git repositories found:"
  printf '%s\n' "$nested_git" >&2
fi

generated_files="$(
  find "$DOTFILES_ROOT" \
    -path "$DOTFILES_ROOT/.git" -prune -o \
    -type f \( \
    -name '*.log' -o \
    -name '*.tmp' -o \
    -name '*.bak' -o \
    -name '*~' \
    \) -print
)"

if [[ -z "$generated_files" ]]; then
  pass "No obvious generated junk files"
else
  warning "Potential generated files found:"
  printf '%s\n' "$generated_files" >&2
fi

finish_verification "Fedora verification"
