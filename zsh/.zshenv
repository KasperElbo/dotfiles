# XDG-based Zsh configuration
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

# PATH policy for every top-level Zsh, interactive or not.
#
# "Top-level" is exact: ZDOTDIR is exported above, and there is no .zshenv in
# it, so a Zsh started from inside a Zsh reads no .zshenv at all and never
# re-runs any of this. A nested shell gets what this file exported (PATH below,
# DISABLE_UPDATES further down), and nothing else here has to reach one.
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
# This is the second line and not the block. It covers every top-level Zsh,
# interactive or not, and everything such a shell starts -- but a Claude Code
# launched by something that is not a descendant of one, an editor or a session
# that predates the install, reads none of this file. The block itself is the
# `env` key of ~/.claude/settings.json, which the tool reads however it was
# started; common/install-ai.sh declares it and common/verify-ai.sh proves it.
# See docs/profiles/ai.md. On a machine that never selected the AI profile this
# variable simply has no reader.
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
