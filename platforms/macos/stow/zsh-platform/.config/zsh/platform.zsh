# Homebrew-managed Zsh plugins. Syntax highlighting intentionally remains last.
#
# Guarded like every other platform: the base profile installs both formulae,
# but a machine that is mid-install, or one whose Homebrew prefix differs,
# must still reach a working prompt instead of two errors at every startup.
[[ ! -r /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] ||
  source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ ! -r /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] ||
  source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
