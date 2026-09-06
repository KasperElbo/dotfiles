#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

failures=0
warnings=0

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

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $(command -v "$command_name")"
  else
    fail "$command_name not found"
  fi
}

check_symlink() {
  local target="$1"
  local expected_prefix="$2"

  if [[ ! -L "$target" ]]; then
    fail "$target is not a symlink"
    return
  fi

  local resolved
  resolved="$(readlink -f "$target")"

  if [[ "$resolved" == "$expected_prefix"* ]]; then
    pass "$target -> $resolved"
  else
    fail "$target resolves outside dotfiles repo: $resolved"
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# ---------------------------------------------------------------------------
# Core commands
# ---------------------------------------------------------------------------

section "Core commands"

commands=(
  bat
  delta
  eza
  fd
  fzf
  gh
  git
  ghostty
  mise
  nvim
  rg
  shellcheck
  sqlite3
  starship
  stow
  tmux
  wl-copy
  wl-paste
  zoxide
  zsh
)

for cmd in "${commands[@]}"; do
  check_command "$cmd"
done

# ---------------------------------------------------------------------------
# Stow-managed configuration
# ---------------------------------------------------------------------------

section "Stow links"

check_symlink "$HOME/.zshenv" \
  "$DOTFILES_ROOT/zsh/"

check_symlink "$XDG_CONFIG_HOME/zsh/.zshrc" \
  "$DOTFILES_ROOT/zsh/"

check_symlink "$XDG_CONFIG_HOME/ghostty/config" \
  "$DOTFILES_ROOT/ghostty/"

check_symlink "$XDG_CONFIG_HOME/git/config" \
  "$DOTFILES_ROOT/git/"

check_symlink "$XDG_CONFIG_HOME/lazygit/config.yml" \
  "$DOTFILES_ROOT/lazygit/"

check_symlink "$XDG_CONFIG_HOME/mise/config.toml" \
  "$DOTFILES_ROOT/mise/"

check_symlink "$XDG_CONFIG_HOME/nvim/init.lua" \
  "$DOTFILES_ROOT/nvim-lazyvim/"

check_symlink "$HOME/.tmux.conf" \
  "$DOTFILES_ROOT/tmux/"

check_symlink "$HOME/.local/bin/theme" \
  "$DOTFILES_ROOT/bin/"

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
fi

# ---------------------------------------------------------------------------
# Optional Sway session
# ---------------------------------------------------------------------------

if [[ -e "$XDG_CONFIG_HOME/sway/config" || -L "$XDG_CONFIG_HOME/sway/config" ]]; then
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
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/"
  check_symlink \
    "$XDG_CONFIG_HOME/xdg-desktop-portal/sway-portals.conf" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/"
  check_symlink "$XDG_CONFIG_HOME/waybar/config.jsonc" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/"
  check_symlink "$XDG_CONFIG_HOME/waybar/style.css" \
    "$DOTFILES_ROOT/platforms/fedora/stow/waybar/"
  check_symlink "$HOME/.local/bin/sway-workspace-grid" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/"
  check_symlink "$HOME/.local/bin/sway-session-start" \
    "$DOTFILES_ROOT/platforms/fedora/stow/sway/"

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

if command -v mise >/dev/null 2>&1; then
  if mise ls >/dev/null 2>&1; then
    pass "mise configuration loads successfully"
  else
    fail "mise could not load configured tools"
  fi

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

  for cmd in "${mise_tools[@]}"; do
    if cmd_path="$(
      mise exec -- bash -c 'command -v "$1"' _ "$cmd" 2>/dev/null
    )" && [[ -n "$cmd_path" ]]; then
      pass "$cmd: $cmd_path"
    else
      fail "mise-managed command missing: $cmd"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Neovim / Mason
# ---------------------------------------------------------------------------

section "Neovim tooling"

mason_root="${XDG_DATA_HOME}/nvim/mason/packages"

mason_packages=(
  angular-language-server
  debugpy
  eslint-lsp
  js-debug-adapter
  json-lsp
  lua-language-server
  netcoredbg
  pyright
  roslyn
  ruff
  shfmt
  stylua
  texlab
  vtsls
  yaml-language-server
)

for package in "${mason_packages[@]}"; do
  if [[ -d "$mason_root/$package" ]]; then
    pass "Mason: $package"
  else
    warning "Mason package not installed: $package"
  fi
done

if [[ -d "$mason_root" ]]; then
  for package_dir in "$mason_root"/*; do
    [[ -d "$package_dir" ]] || continue

    package="$(basename "$package_dir")"
    expected="false"

    for expected_package in "${mason_packages[@]}"; do
      if [[ "$package" == "$expected_package" ]]; then
        expected="true"
        break
      fi
    done

    if [[ "$expected" == "false" ]]; then
      warning "Unexpected Mason package (review ownership): $package"
    fi
  done
fi

if nvim --headless \
  '+lua assert(vim.fn.has("nvim-0.12") == 1)' \
  +qa >/dev/null 2>&1; then
  pass "Neovim >= 0.12"
else
  fail "Neovim startup/version check failed"
fi

# ---------------------------------------------------------------------------
# Optional OCaml profile
# ---------------------------------------------------------------------------

ocaml_state="$XDG_CONFIG_HOME/dotfiles/ocaml.conf"

if [[ -f "$ocaml_state" ]]; then
  section "OCaml profile"

  if "$DOTFILES_ROOT/common/verify-ocaml.sh"; then
    pass "Optional OCaml profile"
  else
    fail "Optional OCaml profile verification failed"
  fi
fi

# ---------------------------------------------------------------------------
# Catppuccin tmux
# ---------------------------------------------------------------------------

section "Catppuccin tmux"

tmux_theme_dir="$XDG_DATA_HOME/tmux/plugins/catppuccin"

if [[ -f "$tmux_theme_dir/catppuccin.tmux" ]]; then
  pass "Catppuccin tmux installed"
else
  fail "Catppuccin tmux is missing"
fi

if [[ -d "$tmux_theme_dir/.git" ]]; then
  expected_tag="v2.3.0"

  installed_commit="$(
    git -C "$tmux_theme_dir" rev-parse HEAD 2>/dev/null || true
  )"

  expected_commit="$(
    git -C "$tmux_theme_dir" rev-list -n 1 "$expected_tag" 2>/dev/null || true
  )"

  if [[ -n "$installed_commit" && "$installed_commit" == "$expected_commit" ]]; then
    pass "Catppuccin tmux $expected_tag"
  else
    warning "Catppuccin tmux is not at expected $expected_tag"
  fi
fi

# ---------------------------------------------------------------------------
# Optional machine hardware
# ---------------------------------------------------------------------------

hardware_state="$XDG_CONFIG_HOME/dotfiles/hardware.conf"

if [[ -f "$hardware_state" ]]; then
  section "ASUS hardware"

  if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-asus-hardware.sh"; then
    pass "ASUS hardware profile verification completed"
  else
    fail "ASUS hardware profile verification failed"
  fi
fi

# ---------------------------------------------------------------------------
# Optional VM host
# ---------------------------------------------------------------------------

vm_host_state="$XDG_CONFIG_HOME/dotfiles/vm-host.conf"

if [[ -f "$vm_host_state" ]]; then
  section "VM host"

  if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-host.sh"; then
    pass "Fedora VM-host profile verification completed"
  else
    fail "Fedora VM-host profile verification failed"
  fi
fi

# ---------------------------------------------------------------------------
# Optional VM guest
# ---------------------------------------------------------------------------

vm_guest_state="$XDG_CONFIG_HOME/dotfiles/vm-guest.conf"

if [[ -f "$vm_guest_state" ]]; then
  section "VM guest"

  if "$DOTFILES_ROOT/platforms/fedora/scripts/verify-vm-guest.sh"; then
    pass "Fedora VM-guest profile verification completed"
  else
    fail "Fedora VM-guest profile verification failed"
  fi
fi

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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'

if ((failures > 0)); then
  printf '\033[1;31mVerification failed:\033[0m %d failure(s), %d warning(s)\n' \
    "$failures" "$warnings"
  exit 1
fi

if ((warnings > 0)); then
  printf '\033[1;33mVerification passed with warnings:\033[0m %d warning(s)\n' \
    "$warnings"
else
  printf '\033[1;32mVerification passed.\033[0m\n'
fi
