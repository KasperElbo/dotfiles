# Fedora-managed Zsh plugin paths.
vm_guest_state="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/vm-guest.conf"
if [[ -r "$vm_guest_state" ]] && grep -Fxq 'profile=vm-guest' "$vm_guest_state"; then
  alias x-copy='xclip -selection clipboard'
fi
unset vm_guest_state

[[ ! -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] ||
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ ! -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] ||
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
