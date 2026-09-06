HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
mkdir -p "${HISTFILE:h}"

HISTSIZE=50000
SAVEHIST=50000

setopt EXTENDED_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt SHARE_HISTORY

setopt AUTO_CD

ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${ZSH_COMPDUMP:h}"

autoload -Uz compinit
compinit -d "$ZSH_COMPDUMP"

# Dotfiles theme
DOTFILES_THEME_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/theme"
DOTFILES_THEME="macchiato"

if [[ -r "$DOTFILES_THEME_FILE" ]]; then
  _dotfiles_theme="$(<"$DOTFILES_THEME_FILE")"

  case "$_dotfiles_theme" in
    latte|frappe|macchiato|mocha)
      DOTFILES_THEME="$_dotfiles_theme"
      ;;
  esac

  unset _dotfiles_theme
fi

export DOTFILES_THEME

# lazygit theme
export LG_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lazygit/config.yml,${XDG_CONFIG_HOME:-$HOME/.config}/lazygit/themes/catppuccin-${DOTFILES_THEME}-mauve.yml"

# bat theme
case "$DOTFILES_THEME" in
  latte)     export BAT_THEME="Catppuccin Latte" ;;
  frappe)    export BAT_THEME="Catppuccin Frappe" ;;
  macchiato) export BAT_THEME="Catppuccin Macchiato" ;;
  mocha)     export BAT_THEME="Catppuccin Mocha" ;;
esac

# zsh theme
# Switch Catppuccin flavour and refresh shell-managed theme variables.
theme() {
  command theme "$@" || return
  exec zsh
}

# Navigation
eval "$(zoxide init zsh)"

# Fuzzy Theming
source "$HOME/.config/fzf/themes/catppuccin-fzf-${DOTFILES_THEME}.sh"

# Fuzzy options
export FZF_CTRL_R_OPTS="
  --height 60%
  --layout=reverse
  --border
  --info=inline
  --preview 'echo {2..} | bat --language=bash --color=always --style=plain'
  --preview-window 'down,35%,wrap'
  --color 'hl+:underline,hl:underline'
"

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

# Startship Theming
export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/catppuccin-${DOTFILES_THEME}.toml"

# Prompt
eval "$(starship init zsh)"

# Platform-owned shell integration. Fedora provides packaged plugin paths here;
# future platforms can provide their own file without changing shared config.
# This remains last so syntax highlighting is initialized in the correct order.
[[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform.zsh" ]] &&
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform.zsh"
