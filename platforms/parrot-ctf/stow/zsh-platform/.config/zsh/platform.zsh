# Keep Bash-like pass-through for unmatched CTF patterns while retaining
# ordinary expansion when files do match. This is deliberately narrower than
# NO_GLOB and avoids a brittle list of per-tool noglob aliases.
unsetopt NOMATCH

# Parrot's reviewed CTF helpers. Generic/cosmetic aliases from the stock Bash
# profile remain excluded so the shared dotfiles conventions stay authoritative.
hex-encode() {
  printf '%s\n' "$*" | xxd -p
}

hex-decode() {
  printf '%s\n' "$*" | xxd -p -r
}

rot13() {
  printf '%s\n' "$*" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
}

alias x-copy='xclip -selection clipboard'

# Parrot/Debian package integration. Syntax highlighting must remain last.
[[ ! -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] ||
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ ! -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] ||
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
