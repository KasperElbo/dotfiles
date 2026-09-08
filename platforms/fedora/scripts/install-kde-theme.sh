#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

require_command git

# kio-extras provides Dolphin's sftp:// support (the KDE SFTP workflow this
# baseline relies on). Installed explicitly rather than assumed, since it is
# not guaranteed to be pulled in as a dependency of every KDE package set.
if rpm -q kio-extras >/dev/null 2>&1; then
  info "kio-extras is already installed"
else
  info "Installing kio-extras for Dolphin sftp:// support"
  sudo dnf install -y kio-extras
fi

version="v0.2.7"
repo="https://github.com/catppuccin/kde.git"
workdir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/catppuccin-kde"

rm -rf "$workdir"
ensure_dir "$(dirname "$workdir")"

info "Downloading Catppuccin KDE $version"

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
