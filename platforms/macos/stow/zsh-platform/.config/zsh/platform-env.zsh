# Native Apple Silicon Homebrew.
#
# coreutils/gnubin is appended rather than prepended. It exists only to supply
# GNU tools macOS does not ship — timeout, used by the shared Neovim bootstrap
# — and must not shadow Apple's ls, date or cp. Appending also makes login and
# non-login shells agree: /etc/zprofile runs path_helper after .zshenv, which
# rebuilds PATH with the system directories in front, so a prepended gnubin
# would lose to /usr/bin in a login shell regardless of what this file says.
typeset -U path PATH
path=(
  /opt/homebrew/bin
  /opt/homebrew/sbin
  $path
  /opt/homebrew/opt/coreutils/libexec/gnubin
)
export PATH
