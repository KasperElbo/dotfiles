# Shared interactive Zsh configuration.
#
# Every optional integration below is guarded. A machine that is missing
# zoxide, fzf, mise or Starship must still get a working interactive shell:
# the missing pieces are recorded and reported on demand by
# `shell-integrations` instead of printing a warning at every startup.

# .zshenv already marks the tied pair unique. Repeat it here so a shell that
# sourced only this file (a rescue shell, a test harness) still cannot grow
# PATH by re-sourcing, and so mise/opam activation stays idempotent.
typeset -gU path PATH

# .zshenv puts ~/.local/bin first, but a login shell runs /etc/zprofile between
# the two files, and on macOS that runs path_helper, which rebuilds PATH with
# the system directories in front and everything else after them. ~/.local/bin
# then sits eighth on a normal Mac, and a terminal window is a login shell, so
# that is the ordinary shape rather than an edge case. Re-assert it here, after
# every system file has had its say. The tied array is unique, so this is a
# no-op in the shells where ~/.local/bin is already first: Zsh keeps the
# leftmost occurrence and drops the later duplicate, moving nothing else.
#
# This is what the command shims depend on -- the Parrot profile's ~/.local/bin
# wrappers for bat and fd only work if they win over anything with the same
# name -- and it is deliberately a prepend here rather than a change to
# path_helper's own inputs, which belong to the operating system.
path=("$HOME/.local/bin" $path)
export PATH

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

# `#` introduces a comment interactively, so a documented command sequence can
# be pasted with its inline notes intact. CORRECT is deliberately not enabled.
setopt INTERACTIVE_COMMENTS

ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${ZSH_COMPDUMP:h}"

# The single completion initialization for the shared profile. Platform files
# and the sections below extend this one compinit; they never re-run it.
autoload -Uz compinit
compinit -d "$ZSH_COMPDUMP"

# Tab opens an interactive menu instead of only listing candidates.
zstyle ':completion:*' menu select

# --- Optional integrations --------------------------------------------------
#
# Missing optional tooling degrades one feature, never the shell. What is
# missing is collected here and printed by `shell-integrations` on request.

typeset -ga DOTFILES_SHELL_MISSING=()

_dotfiles_integration() {
  local tool="$1" consequence="$2"

  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi

  DOTFILES_SHELL_MISSING+=("$tool — $consequence")
  return 1
}

# Answer whether the installer recorded a capability as present on this
# machine. `observed_capabilities` is what was actually installed, as opposed
# to the `requested_capabilities` that were asked for. A missing or unreadable
# state file means no optional capability is active, which is the right answer
# for a machine that never ran the installer and for one that is mid-install.
_dotfiles_capability() {
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/install.conf"
  local line

  [[ -r "$state" ]] || return 1

  while IFS= read -r line; do
    [[ "$line" == observed_capabilities=* ]] || continue
    [[ ",${line#observed_capabilities=}," == *",$1,"* ]]
    return
  done <"$state"

  return 1
}

# Report the optional integrations this shell could not activate. Nonzero
# means the shell is running with reduced functionality.
shell-integrations() {
  if (( ${#DOTFILES_SHELL_MISSING} == 0 )); then
    print -r -- 'All optional shell integrations are active.'
    return 0
  fi

  print -r -- 'This shell is running with reduced functionality:'
  printf '  %s\n' "${DOTFILES_SHELL_MISSING[@]}"
  return 1
}

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
# Switch Catppuccin flavour and refresh the shell-managed theme variables.
#
# Status 3 means the shared theme state is current but an independent platform
# action failed: this shell's prompt, bat, fzf and lazygit theming are all
# correct, so refresh anyway. The command has already printed which action
# failed. Any other nonzero status left the shared state unchanged, so
# restarting would only hide the failure.
theme() {
  # Not named `status`: that is one of Zsh's read-only aliases for `?`.
  local theme_status=0
  command theme "$@" || theme_status=$?

  if (( theme_status == 0 || theme_status == 3 )); then
    exec zsh
  fi

  return "$theme_status"
}

# Navigation
if _dotfiles_integration zoxide 'z and zi directory jumping are unavailable'; then
  eval "$(zoxide init zsh)"
fi

# Fuzzy Theming
_dotfiles_fzf_theme="${XDG_CONFIG_HOME:-$HOME/.config}/fzf/themes/catppuccin-fzf-${DOTFILES_THEME}.sh"
[[ ! -r "$_dotfiles_fzf_theme" ]] || source "$_dotfiles_fzf_theme"
unset _dotfiles_fzf_theme

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

# Fuzzy finder. fzf owns Ctrl-R (fuzzy history), Ctrl-T (files) and Alt-C
# (directories); nothing below rebinds them.
if _dotfiles_integration fzf 'Ctrl-R, Ctrl-T and Alt-C fuzzy bindings are unavailable'; then
  source <(fzf --zsh)
fi

# Convenience
if _dotfiles_integration eza 'ls, ll, la and tree fall back to their system versions'; then
  alias ls='eza'
  alias ll='eza -lah --git'
  alias la='eza -a'
  alias tree='eza --tree'
fi

if _dotfiles_integration bat 'cat is the plain system cat'; then
  alias cat='bat'
fi

# --- Archive helpers --------------------------------------------------------
#
# `tar ARCHIVE PATH...` is a create shorthand and nothing else: the first
# argument must not look like an option and must carry a known archive suffix.
# Every other invocation — `tar -tf a.tgz`, `tar -xf a.tgz`, `tar --help`, and
# `command tar ...` — reaches the native CLI unchanged.
tar() {
  if (( $# >= 2 )) && [[ "$1" != -* ]]; then
    case "$1" in
    (*.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tbz|*.tar.zst|*.tzst|*.tar.lz|*.tar.lzma|*.tar.Z)
      # -a picks the compressor from the suffix. GNU tar has had it since
      # 1.20 and libarchive's bsdtar implements it too, which covers every
      # supported platform.
      command tar -caf "$@"
      return
      ;;
    esac
  fi

  command tar "$@"
}

# Extraction detects the compression itself. `command tar` is mandatory here:
# calling `tar` would re-enter the helper above.
untar() {
  if (( $# == 0 )); then
    print -ru2 -- 'usage: untar ARCHIVE [ARCHIVE...]'
    return 2
  fi

  local archive
  for archive in "$@"; do
    command tar -xf "$archive" || return
  done
}

# --- Line editing -----------------------------------------------------------
#
# Up/Down filter history by whatever is already typed, which complements
# fzf's Ctrl-R fuzzy search rather than replacing it.
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

# terminfo is the portable source for these sequences, but it describes only
# the mode the terminal is in, and only when TERM names a real entry. Ghostty,
# Konsole, the WSL console, Linux VT consoles, SSH and tmux do not agree on
# whether the keypad is in application mode when a line editor starts, and a
# remote TERM may be unknown locally. So each key binds its terminfo sequence
# *and* the documented xterm sequences for both modes.
zmodload zsh/terminfo 2>/dev/null

_dotfiles_bindkey() {
  local widget="$1" sequence
  shift

  for sequence in "$@"; do
    [[ -n "$sequence" ]] || continue
    bindkey -- "$sequence" "$widget"
  done
}

# Home/End/Delete take the xterm "normal" form, the application-cursor form
# and the vt220 numeric form. Ctrl+Left/Right take xterm's modifyOtherKeys
# form, rxvt's lowercase SS3 form and the older CSI form. The uppercase SS3
# sequences \eOD and \eOC are deliberately absent: those are plain Left and
# Right in application-cursor mode and must keep moving by character.
#                                      terminfo             xterm         application   older / vt220
_dotfiles_bindkey beginning-of-line    "${terminfo[khome]}" $'\e[H'       $'\eOH'       $'\e[1~' $'\e[7~'
_dotfiles_bindkey end-of-line          "${terminfo[kend]}"  $'\e[F'       $'\eOF'       $'\e[4~' $'\e[8~'
_dotfiles_bindkey delete-char          "${terminfo[kdch1]}" $'\e[3~'
_dotfiles_bindkey backward-word        "${terminfo[kLFT5]}" $'\e[1;5D'    $'\eOd'       $'\e[5D'
_dotfiles_bindkey forward-word         "${terminfo[kRIT5]}" $'\e[1;5C'    $'\eOc'       $'\e[5C'
_dotfiles_bindkey up-line-or-beginning-search   "${terminfo[kcuu1]}" $'\e[A' $'\eOA'
_dotfiles_bindkey down-line-or-beginning-search "${terminfo[kcud1]}" $'\e[B' $'\eOB'

# Put the terminal into the keypad mode terminfo describes while the line
# editor is active, so the terminfo sequences bound above are the ones the
# terminal actually sends.
if (( ${+terminfo[smkx]} && ${+terminfo[rmkx]} )); then
  autoload -Uz add-zle-hook-widget

  _dotfiles_keypad_start() { echoti smkx }
  _dotfiles_keypad_finish() { echoti rmkx }

  zle -N _dotfiles_keypad_start
  zle -N _dotfiles_keypad_finish

  add-zle-hook-widget line-init _dotfiles_keypad_start
  add-zle-hook-widget line-finish _dotfiles_keypad_finish
fi

# Developmet Toolchains
if _dotfiles_integration mise 'mise-managed runtimes and tools are not on PATH'; then
  eval "$(mise activate zsh)"
fi

# opam owns OCaml compilers and ecosystem tooling when the optional profile is
# installed. The generated hook is sourced from tracked config so `opam init`
# never needs to edit shell startup files.
[[ ! -r "$HOME/.opam/opam-init/init.zsh" ]] ||
  source "$HOME/.opam/opam-init/init.zsh" >/dev/null 2>/dev/null

# `claude-unsafe` starts Claude Code with every permission prompt disabled:
# the agent can then read and write anything this user can, run any command,
# and use every credential the shell can reach, without asking. The name says
# so on purpose (#503); docs/profiles/ai.md has the policy, and
# scripts/validate-actions.py refuses a shorter name, a wrapper function, or a
# registry row that does not pin this whole line. The flag is the only way in:
# a `permissions.defaultMode` of `bypassPermissions` is ignored when it comes
# from repo-level settings, and the mode cannot be raised once the session is
# running.
#
# Gated on the `ai` capability rather than `_dotfiles_integration`: that
# capability is opt-in and off by default, so an absent Claude Code is a
# deliberate choice, not the reduced functionality `shell-integrations`
# reports. The command check keeps a recorded-but-since-removed install from
# leaving behind an alias that resolves to nothing.
#
# Deliberately below `mise activate`, and not up with the other aliases: the
# AI profile installs Claude Code through mise's npm backend, so `claude` only
# exists on PATH once mise has activated. Asked any earlier, the command check
# answers "absent" on every machine that has it, and the alias is never
# defined.
if _dotfiles_capability ai && command -v claude >/dev/null 2>&1; then
  alias claude-unsafe='claude --dangerously-skip-permissions'
fi

# Startship Theming
export STARSHIP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/starship/catppuccin-${DOTFILES_THEME}.toml"

# Prompt
if _dotfiles_integration starship 'the prompt falls back to the Zsh default'; then
  eval "$(starship init zsh)"
fi

# Platform-owned shell integration. Fedora provides packaged plugin paths here;
# future platforms can provide their own file without changing shared config.
# This remains last so syntax highlighting is initialized in the correct order.
if [[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform.zsh" ]]; then
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/platform.zsh"
fi

# Startup must finish with a clean status. Otherwise the very first prompt of
# every shell reports a failure that no command of the user's caused — which
# the prompt's exit-status segment would then display.
true
