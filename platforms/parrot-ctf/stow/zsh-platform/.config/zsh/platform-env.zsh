# Preserve Parrot's distro command-search contract before shared interactive
# startup activates user-managed tools. Zsh's tied unique array removes
# inherited duplicates without changing the order of existing entries.
typeset -gU path PATH

path+=(/usr/local/sbin /usr/sbin /sbin)

# Snap is not required by this profile, but an existing Parrot Snap install
# remains usable. Do not add a dead directory on machines without Snap.
[[ ! -d /snap/bin ]] || path+=(/snap/bin)
