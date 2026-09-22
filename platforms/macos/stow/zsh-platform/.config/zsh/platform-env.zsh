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

# PATH is built by hand above for the ordering reason given; the rest of what
# `brew shellenv` exports is taken as it comes, and these lines are what it
# emits for a /opt/homebrew prefix. They are not decoration: common/verify-ocaml.sh
# and scripts/bootstrap-macos.sh both read HOMEBREW_PREFIX to find Homebrew
# rather than assume the Apple Silicon path, and a variable that is only ever
# read defensively is a trap — it looks like part of the environment contract
# without being one, so the next reader written against it takes a wrong
# default in silence.
export HOMEBREW_PREFIX=/opt/homebrew
export HOMEBREW_CELLAR=/opt/homebrew/Cellar
export HOMEBREW_REPOSITORY=/opt/homebrew
# `man` derives Homebrew's share/man from PATH through /etc/man.conf, so
# Homebrew does not name it here: it only re-adds the leading colon, which
# means "and then the system defaults", to an MANPATH someone else set. Naming
# an explicit path instead would drop the system manuals. INFOPATH has no such
# derivation, so `info` is given the directory.
[ -z "${MANPATH-}" ] || export MANPATH=":${MANPATH#:}"
export INFOPATH="/opt/homebrew/share/info:${INFOPATH:-}"
export PATH
