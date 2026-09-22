# Keep Windows interoperability available through explicit helpers without
# importing the Windows PATH into the Linux development environment.
typeset -a _dotfiles_linux_path
typeset _dotfiles_path_entry

for _dotfiles_path_entry in "${path[@]}"; do
  case "$_dotfiles_path_entry" in
  /mnt/[a-zA-Z]/*) ;;
  *) _dotfiles_linux_path+=("$_dotfiles_path_entry") ;;
  esac
done

if (( ${#_dotfiles_linux_path} )); then
  path=("${_dotfiles_linux_path[@]}")
else
  # Every entry was a Windows mount. Assigning the empty array here would leave
  # the login shell with no commands at all and nothing saying why -- the shell
  # would come up and every name typed into it would be "not found". Keeping the
  # unsanitized PATH is the recoverable failure, so the situation is named on
  # stderr instead of being enacted silently.
  print -u2 -- \
    'dotfiles: every PATH entry is a Windows mount; leaving PATH unsanitized.'
fi
export PATH
unset _dotfiles_linux_path _dotfiles_path_entry

# Linux tools can deliberately open a URL or file with its Windows handler.
export BROWSER=wsl-open
