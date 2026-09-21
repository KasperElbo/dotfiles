#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/tool-floors.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tool-floors.sh"
# shellcheck source=lib/mason.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/mason.sh"

establish_user_tool_environment
require_command nvim
require_command timeout
# Deciding whether a package is installed means reading its Mason receipt, and
# a run that could not read one would fall back to trusting a directory, which
# is what this installer stopped doing.
require_command jq

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

mapfile -t mason_packages < <(mason_read_inventory "$inventory_file")
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
# the recorded version; everything else tracks the refreshed registries. The
# pins are parsed by lib/mason.sh so the verifier compares the same file this
# installer installs from.
version_pin_file="$DOTFILES_ROOT/common/mason-package-versions.txt"
mason_load_version_pins "$version_pin_file" || die "$MASON_ERROR"

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
mason_install_root="$(mason_root)"
mason_bin="$mason_install_root/bin"

# Restore only Mason while nvim-treesitter is disabled by the bootstrap profile.
# This gives the blocking installer a usable Mason API without allowing
# LazyVim's asynchronous Treesitter build/config callbacks to install the same
# tree-sitter-cli package concurrently.
run_nvim_phase 1 "Preparing Mason plugin" '+Lazy! restore mason.nvim' +qa
[[ -d "$mason_plugin" ]] || die "Mason plugin was not restored: $mason_plugin"

# What to install is decided from Mason's own receipts, never from a package
# directory: Mason writes the receipt last, so a directory is evidence that an
# installation was started and not that one finished. A package that exists but
# is incomplete, or exists at a version the pin file no longer names, is a
# repair and not a fresh install, and repairs go in their own list because
# Mason has to be told to force them. Without that it refuses to relink over
# the links the earlier attempt left behind, and refuses outright while that
# attempt's staging lock is still on disk -- which is exactly the state an
# interrupted run leaves. The version pin is applied to both lists, so a
# package that already exists no longer escapes the pin.
install_targets=()
repair_targets=()
for package in "${mason_packages[@]}"; do
  pinned_version="$(mason_version_pin "$package")"
  if mason_package_status "$mason_install_root" "$package" "$pinned_version"; then
    continue
  fi
  install_target="$package"
  if [[ -n "$pinned_version" ]]; then
    info "Pinning Mason package $package to $pinned_version"
    install_target="$package@$pinned_version"
  fi
  if [[ "$MASON_PACKAGE_STATE" == absent ]]; then
    install_targets+=("$install_target")
  else
    warn "Repairing Mason package $package: $MASON_PACKAGE_DETAIL"
    repair_targets+=("$install_target")
  fi
done

if ((${#install_targets[@]} > 0 || ${#repair_targets[@]} > 0)); then
  install_list=""
  repair_list=""
  ((${#install_targets[@]} == 0)) || install_list="${install_targets[*]}"
  ((${#repair_targets[@]} == 0)) || repair_list="${repair_targets[*]}"

  # Load Mason directly for this phase. MasonInstall blocks until the complete
  # declared inventory has converged, so tree-sitter-cli has one installer.
  DOTFILES_MASON_PLUGIN="$mason_plugin" \
    DOTFILES_MASON_PACKAGES="$install_list" \
    DOTFILES_MASON_REPAIR_PACKAGES="$repair_list" \
    run_nvim_phase 1 "Installing Mason editor tools" \
    -u NONE -l "$DOTFILES_ROOT/common/bootstrap-mason.lua"
else
  info "All intended Mason editor tools are already installed"
fi

# Convergence is re-established from the receipts, by the same rule, so a
# provisioning run cannot report success over a package Mason did not finish.
unconverged_packages=()
for package in "${mason_packages[@]}"; do
  pinned_version="$(mason_version_pin "$package")"
  if mason_package_status "$mason_install_root" "$package" "$pinned_version"; then
    continue
  fi
  warn "Mason package did not converge: $package ($MASON_PACKAGE_DETAIL)"
  unconverged_packages+=("$package")
done

if ((${#unconverged_packages[@]} > 0)); then
  die "Mason provisioning incomplete; unconverged: ${unconverged_packages[*]}"
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
