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

path=("${_dotfiles_linux_path[@]}")
export PATH
unset _dotfiles_linux_path _dotfiles_path_entry

# Linux tools can deliberately open a URL or file with its Windows handler.
export BROWSER=wsl-open
