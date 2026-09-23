# PATH policy for every Zsh *login*, interactive or not.
#
# mise is activated in .zshrc, which only an interactive shell reads. A login
# that is not interactive (`zsh -lc ...`, and anything started through one)
# used to read .zshenv and nothing else of ours, so it ran whatever the system
# package manager had installed under the same name (python and node in
# /usr/bin, or Homebrew's), while an interactive terminal ran mise's. mise
# documents its shims directory for exactly that shell, and that is all this
# file adds.
#
# Why here and not in .zshenv: a login runs /etc/zprofile after .zshenv, and on
# macOS that runs path_helper, which rebuilds PATH with the system directories
# in front of everything .zshenv put there (see platform-env.zsh there). This
# file is read after /etc/zprofile, so what it puts in front stays in front:
# after it a login that is not interactive reads only /etc/zlogin and
# $ZDOTDIR/.zlogin, and this repository tracks no .zlogin. It is also read by
# login shells only, so a plain `zsh -c` script is left as it was.
#
# ~/.local/bin is re-asserted first for the same path_helper reason .zshrc gives,
# and the shims follow it, ahead of every system directory. An interactive login
# goes on to read .zshrc, whose `mise activate` puts the install directories of
# the active versions ahead of both, so an interactive shell resolves exactly
# what it did before; the tied array is unique (.zshenv), so none of this can
# duplicate an entry however often it runs.
#
# The directory is resolved the way mise resolves it, and the way
# establish_user_tool_environment and the verifier's check_mise_owned
# (common/lib) do. It is added only when it exists: like every optional
# integration in .zshrc, a machine without mise is left alone, silently.

typeset -gU path PATH

() {
  local mise_shims="${MISE_SHIMS_DIR:-${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims}"

  if [[ -d "$mise_shims" ]]; then
    path=("$HOME/.local/bin" "$mise_shims" $path)
  else
    path=("$HOME/.local/bin" $path)
  fi
}
export PATH
