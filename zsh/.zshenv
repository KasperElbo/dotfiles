# XDG-based Zsh configuration
export ZDOTDIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"

# User executables
export PATH="$HOME/.local/bin:$PATH"

# Platform environment policy must run before .zshrc executes any commands.
# Fedora WSL uses this hook to remove inherited Windows PATH entries while
# keeping interop available through explicit helpers.
[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform-env.zsh" ]] &&
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform-env.zsh"
