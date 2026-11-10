# Preserve Parrot's distro command-search contract before shared interactive
# startup activates user-managed tools. Zsh's tied unique array removes
# inherited duplicates without changing the order of existing entries.
typeset -gU path PATH

# Parrot's Zsh login chain never builds a PATH of its own. /etc/zsh/zprofile is
# pure comments, so unlike most Debian systems it does not source /etc/profile,
# and /etc/zsh/zshenv assigns a PATH only when it is empty or exactly
# "/bin:/usr/bin". Every other case inherits the caller's PATH verbatim and no
# later file supplies a distro directory.
#
# So these are stated rather than assumed. A login started from a process with
# a thin PATH used to keep it all the way through, which made the verifier's
# login-PATH check a readout of whoever ran the installer instead of a test of
# this file -- the install failed on a missing /usr/bin that the login chain
# had never been asked to provide.
#
# Appending is safe: the tied unique array above keeps the first occurrence of
# each entry, so a PATH that already resolves these correctly is neither
# reordered nor grown, and sourcing this file twice changes nothing.
path+=(/usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin)

# Snap is not required by this profile, but an existing Parrot Snap install
# remains usable. Do not add a dead directory on machines without Snap.
[[ ! -d /snap/bin ]] || path+=(/snap/bin)
