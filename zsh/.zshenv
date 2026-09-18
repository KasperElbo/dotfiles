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

# Claude Code is installed and updated by mise, as `npm:@anthropic-ai/claude-code`
# in the optional AI profile. Left to itself it installs a second copy under the
# mise-managed Node prefix, which then shadows the dedicated npm-backend
# installation and makes the AI verifier fail on a duplicated provider.
#
# `DISABLE_UPDATES` blocks every update path. The more commonly cited
# `DISABLE_AUTOUPDATER` stops only the background check and leaves `claude
# update` and `claude install` able to do exactly the same thing, which is not
# what "mise owns this package" means.
#
# Set here rather than behind the AI profile because this file is read by every
# Zsh, interactive or not, which is what makes the setting effective in a fresh
# login shell however Claude Code is started. On a machine that never selected
# the AI profile the variable simply has no reader.
export DISABLE_UPDATES=1

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
