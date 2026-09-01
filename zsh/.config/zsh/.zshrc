export ZDOTDIR="$HOME/.config/zsh"

HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
mkdir -p "${HISTFILE:h}"

HISTSIZE=10000
SAVEHIST=10000

setopt HIST_IGNORE_DUPS
setopt SHARE_HISTORY
setopt AUTO_CD

ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${ZSH_COMPDUMP:h}"

autoload -Uz compinit
compinit -d "$ZSH_COMPDUMP"

# Navigation
eval "$(zoxide init zsh)"

# Fuzzy finder
source <(fzf --zsh)

# Convenience
alias ls='eza'
alias ll='eza -lah --git'
alias la='eza -a'
alias tree='eza --tree'
alias cat='bat'

# Developmet Toolchains
eval "$(mise activate zsh)"

# Prompt
eval "$(starship init zsh)"
