#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

require_command git

# Two packages this capability needs and no KDE package set guarantees, so
# both are installed explicitly rather than assumed.
#
# kio-extras provides Dolphin's sftp:// support, the KDE SFTP workflow this
# baseline relies on.
#
# wget is what the pinned upstream installer downloads the Catppuccin cursors
# with, and it checks for it before installing anything: without it the first
# flavour stops at "Error: Dependency 'wget' is not met." and no theme is
# installed at all. Cursor installation stays enabled below, so the dependency
# is real rather than avoidable.
#
# unzip is checked on the same line of the same installer and is just as
# unavoidable, but it is not listed here: it is a generic utility the base
# capability owns, and package ownership is single-owner, so naming it twice
# fails validation. This capability depends on base, so base installing it is
# the declaration (#360).
packages=(kio-extras wget)
for package in "${packages[@]}"; do
  if rpm -q "$package" >/dev/null 2>&1; then
    info "$package is already installed"
  else
    info "Installing $package"
    sudo dnf install -y "$package"
  fi
done

# kpackagetool6 is the third dependency the pinned upstream installer checks,
# after wget and tar, and a missing one stops it before the first flavour just
# as loudly. It installs the look-and-feel packages built from the generated
# theme data, so no shim can stand in for it the way the two Plasma commands
# below are shimmed. The Fedora KDE spin carries it, but this capability
# declares what it needs rather than assuming the spin.
#
# Requested by the path it provides rather than by a package name: dnf resolves
# a file provide out of the primary metadata, and a Fedora package rename then
# cannot quietly stop satisfying it.
if command -v kpackagetool6 >/dev/null 2>&1; then
  info "kpackagetool6 is already available"
else
  info "Installing the package that provides kpackagetool6"
  sudo dnf install -y /usr/bin/kpackagetool6
fi

# A Plasma desktop, and not merely its tools. The upstream installer installs
# each flavour's global theme with `kpackagetool6 -t Plasma/LookAndFeel -i`,
# and kpackagetool6 can only do that when the KPackage package structure plugin
# for that type is present. That plugin comes with the Plasma desktop, so a
# machine carrying the tool and no desktop clears every dependency check above
# and then dies inside the first flavour with "Could not load package structure
# Plasma/LookAndFeel" -- after that flavour's Aurorae and colour-scheme assets
# have already been written. That is how the 2026-09-21 scheduled installation
# failed.
#
# This capability themes an existing Plasma installation and deliberately does
# not install one: --kde on a machine that does not run Plasma has to say so
# rather than pull in a desktop session behind the user's back.
#
# plasma-apply-lookandfeel stands in for the desktop, because it arrives with
# the same Plasma package as the structure plugin and because it is what the
# upstream installer itself looks for. It is shimmed further down so that
# installing a theme never applies one; that shim stands in for the command,
# not for the desktop, which is why the real one is required here first.
command_exists plasma-apply-lookandfeel || die \
  "This machine has no KDE Plasma desktop: plasma-apply-lookandfeel was not" \
  "found. The KDE capability themes an existing Plasma installation and does" \
  "not install one. Install Plasma, or rerun with --no-kde."

version="v0.4.0"
repo="https://github.com/catppuccin/kde.git"
workdir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/catppuccin-kde"

rm -rf "$workdir"
ensure_dir "$(dirname "$workdir")"

info "Downloading Catppuccin KDE $version"

# network-source: catppuccin-kde
git clone \
  --branch "$version" \
  --depth 1 \
  "$repo" \
  "$workdir"

cd "$workdir"

# The pinned upstream installer has no install-without-apply mode. Its "auto"
# mode always calls these commands after installing a flavour, which would make
# Plasma visibly cycle through every theme. Keep the install path intact while
# deferring all desktop changes to the repository's theme command.
command_shim_dir="$workdir/.dotfiles-command-shims"
ensure_dir "$command_shim_dir"

cat >"$command_shim_dir/plasma-apply-lookandfeel" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$command_shim_dir/plasma-apply-lookandfeel"
ln -sf plasma-apply-lookandfeel "$command_shim_dir/kwriteconfig6"

# Catppuccin KDE installer choices:
#
# flavour (upstream numbering):
#   1 = Mocha
#   2 = Macchiato
#   3 = Frappé
#   4 = Latte
#
# accent:
#   4 = Mauve
#
# window decoration:
#   2 = Classic
#
# "auto" = non-interactive installation.
#
# Cursor installation remains enabled.

for flavour in 1 2 3 4; do
  info "Installing Catppuccin KDE flavour $flavour"
  PATH="$command_shim_dir:$PATH" ./install.sh "$flavour" 4 2 auto
done

success "All Catppuccin KDE flavours installed"
