# Native Apple Silicon Homebrew. coreutils/gnubin supplies GNU timeout for the
# shared Neovim bootstrap without shadowing Apple's tools elsewhere.
typeset -U path PATH
path=(
  /opt/homebrew/opt/coreutils/libexec/gnubin
  /opt/homebrew/bin
  /opt/homebrew/sbin
  $path
)
export PATH
