#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tool-floors.sh"

establish_user_tool_environment
require_command nvim
require_command timeout

profile="workstation"

while (($#)); do
  case "$1" in
  --profile)
    [[ $# -ge 2 ]] || die "--profile requires a value"
    profile="$2"
    shift 2
    ;;
  *) die "Unknown option: $1" ;;
  esac
done

case "$profile" in
workstation)
  inventory_file="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"
  ;;
parrot-ctf)
  inventory_file="$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"
  ;;
*) die "Unsupported Neovim profile: $profile" ;;
esac

[[ -r "$inventory_file" ]] || die "Mason package inventory not found: $inventory_file"

mapfile -t mason_packages < <(
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$inventory_file"
)
((${#mason_packages[@]} > 0)) || die "Mason package inventory is empty"

for package in "${mason_packages[@]}"; do
  [[ "$package" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "Invalid Mason package name in inventory: $package"
done

if ! printf '%s\n' "${mason_packages[@]}" | grep -Fxq 'tree-sitter-cli'; then
  die "Mason inventory must include tree-sitter-cli so bootstrap has one explicit owner"
fi

# Optional pins for packages whose registry advertises a build before that
# build's platform archives exist upstream. Pinned packages are installed at
# the recorded version; everything else tracks the refreshed registries.
version_pin_file="$DOTFILES_ROOT/common/mason-package-versions.txt"
mason_version_pins=()
if [[ -e "$version_pin_file" ]]; then
  [[ -r "$version_pin_file" ]] ||
    die "Mason version pin file is not readable: $version_pin_file"

  while IFS= read -r pin_line; do
    read -r pin_package pin_version pin_extra <<<"$pin_line"
    [[ -n "${pin_package:-}" ]] || continue
    [[ -z "${pin_extra:-}" ]] || die "Invalid Mason version pin: $pin_line"
    [[ "$pin_package" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
      die "Invalid Mason package name in version pins: $pin_package"
    [[ -n "${pin_version:-}" ]] ||
      die "Mason version pin is missing a version: $pin_package"
    [[ "$pin_version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] ||
      die "Invalid Mason version pin for $pin_package: $pin_version"

    # The same pin file serves every profile, so a pin for a package this
    # profile does not install is not an error.
    printf '%s\n' "${mason_packages[@]}" | grep -Fxq "$pin_package" || continue
    mason_version_pins+=("$pin_package=$pin_version")
  done < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$version_pin_file")
fi

mason_version_pin() {
  local package="$1"
  local pin

  for pin in ${mason_version_pins[@]+"${mason_version_pins[@]}"}; do
    if [[ "$pin" == "$package="* ]]; then
      printf '%s\n' "${pin#*=}"
      return 0
    fi
  done
}

bootstrap_timeout="${NEOVIM_BOOTSTRAP_TIMEOUT:-20m}"
[[ "$bootstrap_timeout" =~ ^[1-9][0-9]*[smhd]?$ ]] ||
  die "Invalid NEOVIM_BOOTSTRAP_TIMEOUT: $bootstrap_timeout"

nvim_command=(nvim)
mise_command="$(command -v mise 2>/dev/null || true)"
if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi
if [[ -n "$mise_command" ]]; then
  # Mason's npm- and Python-based packages need the runtimes installed by mise
  # even though this non-interactive Bash process has not activated mise.
  nvim_command=("$mise_command" exec -- nvim)
fi

# Bootstrap phases run from the deterministic mise context (see lib/common.sh),
# so an installer started inside an unrelated project cannot have that
# project's .mise.toml decide which Neovim or which runtimes Mason builds
# against. Every phase argument is a "+command", never a path, so the neutral
# working directory changes nothing else.
#
# Prepared here rather than below the floor check, because that check is itself
# a run_mise call and run_mise no longer prepares: only install-time code does.
mise_context="$(mise_prepare_context)"

# Checked against the Neovim these phases will actually run -- mise's, when
# mise owns it, not whatever else is on PATH -- and before the first headless
# phase. Below the floor, Mason fails partway through with a Lua error that
# names neither Neovim nor a version (vim.uv is 0.10+, vim.iter 0.12+).
#
# Asked through run_mise, for the same reason the phases below use the
# deterministic context (see lib/common.sh): run from the checkout's own
# directory, `mise exec` resolves this repository's tool configuration and
# answers nothing, which would refuse a Neovim that is perfectly current.
nvim_version_probe=(nvim)
[[ -z "$mise_command" ]] ||
  nvim_version_probe=(run_mise "$mise_command" exec -- nvim)
tool_floor_check nvim "${nvim_version_probe[@]}" ||
  die "Install a newer Neovim first: DNF on Fedora, Homebrew on macOS, or the pinned mise tool on the Parrot CTF guest."

run_nvim_phase() {
  local bootstrap_mode="$1"
  local description="$2"
  shift 2
  local status

  info "$description"
  if (
    cd -- "$mise_context" || exit 1
    DOTFILES_NVIM_PROFILE="$profile" DOTFILES_MASON_BOOTSTRAP="$bootstrap_mode" \
      MISE_CEILING_PATHS="$mise_context" \
      timeout --kill-after=30s \
      "$bootstrap_timeout" "${nvim_command[@]}" --headless "$@"
  ); then
    return
  else
    status=$?
  fi

  if ((status == 124 || status == 137)); then
    die "$description timed out after $bootstrap_timeout"
  fi
  die "$description failed with exit status $status"
}

mason_plugin="$XDG_DATA_HOME/nvim/lazy/mason.nvim"
mason_root="$XDG_DATA_HOME/nvim/mason/packages"
mason_bin="$XDG_DATA_HOME/nvim/mason/bin"

# Restore only Mason while nvim-treesitter is disabled by the bootstrap profile.
# This gives the blocking installer a usable Mason API without allowing
# LazyVim's asynchronous Treesitter build/config callbacks to install the same
# tree-sitter-cli package concurrently.
run_nvim_phase 1 "Preparing Mason plugin" '+Lazy! restore mason.nvim' +qa
[[ -d "$mason_plugin" ]] || die "Mason plugin was not restored: $mason_plugin"

missing_packages=()
for package in "${mason_packages[@]}"; do
  [[ -d "$mason_root/$package" ]] || missing_packages+=("$package")
done

if ((${#missing_packages[@]} > 0)); then
  install_targets=()
  for package in "${missing_packages[@]}"; do
    pinned_version="$(mason_version_pin "$package")"
    if [[ -n "$pinned_version" ]]; then
      info "Pinning Mason package $package to $pinned_version"
      install_targets+=("$package@$pinned_version")
    else
      install_targets+=("$package")
    fi
  done

  # Load Mason directly for this phase. MasonInstall blocks until the complete
  # declared inventory has converged, so tree-sitter-cli has one installer.
  DOTFILES_MASON_PLUGIN="$mason_plugin" \
    DOTFILES_MASON_PACKAGES="${install_targets[*]}" \
    run_nvim_phase 1 "Installing Mason editor tools" \
    -u NONE -l "$DOTFILES_ROOT/common/bootstrap-mason.lua"
else
  info "All intended Mason editor tools are already installed"
fi

remaining_packages=()
for package in "${mason_packages[@]}"; do
  [[ -d "$mason_root/$package" ]] || remaining_packages+=("$package")
done

if ((${#remaining_packages[@]} > 0)); then
  die "Mason provisioning incomplete; missing: ${remaining_packages[*]}"
fi

[[ -x "$mason_bin/tree-sitter" ]] ||
  die "Mason tree-sitter-cli is installed but does not expose $mason_bin/tree-sitter"

# Only after the blocking Mason inventory has converged do we enable the normal
# nvim-treesitter spec. Put Mason's bin directory on PATH explicitly so
# LazyVim's Treesitter health/build callbacks observe the already-installed CLI
# before Mason's normal interactive configuration has a chance to modify PATH.
restore_log="$(mktemp)"
if PATH="$mason_bin:$PATH" run_nvim_phase 0 "Restoring LazyVim plugins" '+Lazy! restore' +qa \
  > >(tee "$restore_log") 2>&1; then
  :
fi
# These diagnostics mean bootstrap ownership regressed and LazyVim tried to
# install tree-sitter-cli even though the blocking Mason phase already owns it.
# The backticks are literal fragments of LazyVim's diagnostic.
# shellcheck disable=SC2016
if grep -Eq \
  'Package is already installing|Neovim is exiting while packages are still installing|Failed to install `tree-sitter-cli` with `mason.nvim`|Installing `tree-sitter-cli` with `mason.nvim`' \
  "$restore_log"; then
  rm -f -- "$restore_log"
  die "LazyVim restore attempted a competing tree-sitter-cli installation"
fi
rm -f -- "$restore_log"

PATH="$mason_bin:$PATH" run_nvim_phase 0 "Verifying LazyVim headless startup" +qa

success "LazyVim plugins and Mason editor tools installed"
