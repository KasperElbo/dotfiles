# Fedora-managed Zsh plugin paths. Syntax highlighting intentionally remains
# last.
#
# Guarded like every other platform: the base profile installs both packages,
# but a machine that is mid-install must still reach a working prompt instead
# of two errors at every startup.
[[ ! -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] ||
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ ! -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] ||
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
