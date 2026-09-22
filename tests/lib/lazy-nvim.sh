#!/usr/bin/env bash

# Where the lazy.nvim checkout the test run needs is, and whether it is there.
#
# `tests/test-neovim-tool-ownership.sh` resolves this repository's plugin
# fragments through lazy.nvim itself rather than reading them, so a checkout is
# a hard requirement of that suite. `./scripts/test.sh`'s aggregate preflight
# needs the same answer, to refuse the run up front instead of letting suite 38
# of 85 fail in the middle of it. Two copies of the resolution rule would be two
# chances for the runner to preflight a path the suite does not use, which is
# worse than not preflighting at all: the run would be refused for a checkout
# that is present, or admitted for one that is missing.
#
# Sourced by both, so there is one rule. It defines functions and touches
# nothing else, so either caller may source it at any point.

# lazy_nvim_checkout: the path a test run will look in.
#
# DOTFILES_LAZY_NVIM when it names one, and otherwise the path a normal install
# already leaves behind. Printed rather than returned, so the caller decides
# whether a missing checkout is a refusal or a failure.
lazy_nvim_checkout() {
  printf '%s\n' "${DOTFILES_LAZY_NVIM:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim}"
}

# lazy_nvim_is_ready <path>: is that a checkout something can resolve specs with?
#
# `lua/lazy` rather than the directory itself, because an empty directory, a
# half-finished clone and a stale path all pass a bare `-d` and then fail
# somewhere further in with a message about Lua.
lazy_nvim_is_ready() {
  [[ -d "${1:?lazy_nvim_is_ready needs a path}/lua/lazy" ]]
}
