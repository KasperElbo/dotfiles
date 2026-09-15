# XDG-based Zsh configuration
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

# PATH policy for every Zsh, interactive or not.
#
# Zsh ties the `path` array to `PATH`; marking the pair unique makes every
# later prepend or append idempotent, in this file, in platform files, and in
# tool initializers such as mise and opam. Zsh keeps the *first* occurrence of
# a duplicated entry, so deliberate precedence is preserved and nothing is
# reordered or sorted: re-sourcing .zshenv or .zshrc cannot grow PATH.
typeset -gU path PATH

# User executables
path=("$HOME/.local/bin" $path)
export PATH

# Platform environment policy must run before .zshrc executes any commands.
# Fedora WSL uses this hook to remove inherited Windows PATH entries while
# keeping interop available through explicit helpers.
#
# An `if` rather than a trailing `&&`: startup must not leave a failed status
# behind for the first prompt (and for the prompt's exit-status segment) to
# report just because an optional platform file is absent.
if [[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform-env.zsh" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform-env.zsh"
fi
