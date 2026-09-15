#!/usr/bin/env bash
# Shared Zsh startup, PATH policy and interactive ergonomics (issues #157/#168).
#
# Every assertion here runs a real `zsh -f` against the tracked startup files
# in a sandboxed HOME, so what is checked is the shell's own resolution rather
# than a grep over the configuration text.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

zsh_path="$(command -v zsh 2>/dev/null || true)"
[[ -n "$zsh_path" ]] || {
  printf 'zsh is required for the shared shell startup tests.\n' >&2
  exit 1
}

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

zshenv="$repo_root/zsh/.zshenv"
zshrc="$repo_root/zsh/.config/zsh/.zshrc"

sandbox_bin="$root/sandbox-bin"
tool_bin="$root/tool-bin"
mkdir -p "$sandbox_bin" "$tool_bin" "$root/config/fzf/themes"

# A minimal real PATH: the shared config must work with nothing but coreutils.
for command_name in bash cat chmod dirname env file grep head mkdir mktemp mv rm sort tar gzip xz; do
  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  [[ -z "$command_path" ]] || ln -sf "$command_path" "$sandbox_bin/$command_name"
done

# Fakes for the optional integrations, used only by the "everything present"
# cases. They emit the shell code the real tools emit, minus the work.
cat >"$tool_bin/zoxide" <<'EOF'
#!/usr/bin/env bash
printf 'z() { builtin cd "$@"; }\nzi() { builtin cd "$@"; }\n'
EOF
cat >"$tool_bin/mise" <<'EOF'
#!/usr/bin/env bash
printf 'export DOTFILES_TEST_MISE_ACTIVATED=1\n'
EOF
cat >"$tool_bin/starship" <<'EOF'
#!/usr/bin/env bash
printf 'export DOTFILES_TEST_STARSHIP_INIT=1\n'
EOF
# The real `fzf --zsh` binds Ctrl-R to its own history widget.
cat >"$tool_bin/fzf" <<'EOF'
#!/usr/bin/env bash
cat <<'ZSH'
fzf-history-widget() { :; }
zle -N fzf-history-widget
bindkey '^R' fzf-history-widget
ZSH
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$tool_bin/eza"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tool_bin/bat"
chmod +x "$tool_bin"/*

printf '# Catppuccin fzf colors\nexport DOTFILES_TEST_FZF_THEME=1\n' \
  >"$root/config/fzf/themes/catppuccin-fzf-macchiato.sh"

# run_zsh <mode> <term> <script>
#
# mode "bare" exposes only coreutils, so every optional integration is absent.
# mode "full" additionally exposes the fakes above.
run_zsh() {
  local mode="$1" term="$2" script="$3" shell_path="$sandbox_bin"
  [[ "$mode" != full ]] || shell_path="$tool_bin:$sandbox_bin"

  env -i \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" \
    TERM="$term" \
    PATH="$shell_path" \
    DOTFILES_TEST_ZSHENV="$zshenv" \
    DOTFILES_TEST_ZSHRC="$zshrc" \
    DOTFILES_TEST_WORK="$root/archives" \
    DOTFILES_TEST_EXTRACT="${DOTFILES_TEST_EXTRACT:-}" \
    "$zsh_path" -f -c "
      source \"\$DOTFILES_TEST_ZSHENV\"
      source \"\$DOTFILES_TEST_ZSHRC\"
      $script
    "
}

# --- PATH policy (#157) -----------------------------------------------------

path_after_sourcing() {
  local repeats="$1" mode="${2:-bare}" shell_path="$sandbox_bin"
  [[ "$mode" != full ]] || shell_path="$tool_bin:$sandbox_bin"

  env -i \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" \
    TERM=xterm-256color \
    PATH="$shell_path" \
    DOTFILES_TEST_ZSHENV="$zshenv" \
    DOTFILES_TEST_ZSHRC="$zshrc" \
    "$zsh_path" -f -c "
      repeat $repeats; do
        source \"\$DOTFILES_TEST_ZSHENV\"
        source \"\$DOTFILES_TEST_ZSHRC\"
      done
      print -l -- \$path
    "
}

once="$(path_after_sourcing 1)"
three_times="$(path_after_sourcing 3)"

assert_eq "$once" "$three_times" 'repeated startup changed PATH'

duplicates="$(printf '%s\n' "$three_times" | sort | uniq -d)"
[[ -z "$duplicates" ]] || {
  printf 'TEST FAILURE: repeated startup duplicated PATH entries:\n%s\n' \
    "$duplicates" >&2
  exit 1
}

assert_eq "$root/home/.local/bin" "$(printf '%s\n' "$three_times" | head -n1)" \
  'user executables must keep the front of PATH'
printf 'PASS: repeated startup keeps PATH unique and ordered\n'

# The tied array must stay unique for later prepends too: mise activation and
# opam both prepend on every shell, and a non-unique array would grow.
uniqueness="$(run_zsh bare xterm-256color '
  path=(/opt/example $path)
  path=(/opt/example $path)
  print -r -- ${#${(M)path:#/opt/example}}
')"
assert_eq 1 "$uniqueness" 'a repeated prepend must not duplicate an entry'
printf 'PASS: later prepends stay idempotent\n'

# Platform PATH files are layered on top and must not be reordered by us.
parrot_env="$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform-env.zsh"
macos_env="$repo_root/platforms/macos/stow/zsh-platform/.config/zsh/platform-env.zsh"
for platform_env in "$parrot_env" "$macos_env"; do
  layered="$(
    env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
      XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
      XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
      DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZSHRC="$zshrc" \
      DOTFILES_TEST_PLATFORM_ENV="$platform_env" \
      "$zsh_path" -f -c "
        repeat 3; do
          source \"\$DOTFILES_TEST_ZSHENV\"
          source \"\$DOTFILES_TEST_PLATFORM_ENV\"
          source \"\$DOTFILES_TEST_ZSHRC\"
        done
        print -l -- \$path
      "
  )"
  platform_duplicates="$(printf '%s\n' "$layered" | sort | uniq -d)"
  [[ -z "$platform_duplicates" ]] || {
    printf 'TEST FAILURE: %s duplicated PATH entries:\n%s\n' \
      "$platform_env" "$platform_duplicates" >&2
    exit 1
  }
done

# macOS keeps Homebrew coreutils' gnubin last so Apple's tools stay in front;
# the shared uniqueness policy must not move it (issues #141/#204).
macos_path="$(
  env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
    DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZSHRC="$zshrc" \
    DOTFILES_TEST_PLATFORM_ENV="$macos_env" \
    "$zsh_path" -f -c "
      repeat 2; do
        source \"\$DOTFILES_TEST_ZSHENV\"
        source \"\$DOTFILES_TEST_PLATFORM_ENV\"
        source \"\$DOTFILES_TEST_ZSHRC\"
      done
      print -l -- \$path
    "
)"
assert_eq '/opt/homebrew/opt/coreutils/libexec/gnubin' \
  "$(printf '%s\n' "$macos_path" | tail -n1)" \
  'macOS gnubin must stay the last PATH entry'
assert_contains "$macos_path" '/opt/homebrew/bin'
printf 'PASS: platform PATH contracts survive the uniqueness policy\n'

# --- Missing optional integrations (#157) -----------------------------------

run_capture run_zsh bare xterm-256color 'print -r -- loaded'
assert_success
assert_contains "$TEST_OUTPUT" 'loaded'
assert_not_contains "$TEST_OUTPUT" 'command not found'
printf 'PASS: a shell without zoxide/fzf/mise/starship still starts\n'

# Degradation is reported on request, never printed on every startup.
startup_noise="$(run_zsh bare xterm-256color 'true')"
assert_eq '' "$startup_noise" 'startup must stay quiet when tools are missing'

run_capture run_zsh bare xterm-256color 'shell-integrations'
assert_status 1
for tool in zoxide fzf mise starship; do
  assert_contains "$TEST_OUTPUT" "$tool"
done
printf 'PASS: missing integrations are reported on demand, not at startup\n'

run_capture run_zsh full xterm-256color 'shell-integrations'
assert_success
assert_contains "$TEST_OUTPUT" 'All optional shell integrations are active.'

activated="$(run_zsh full xterm-256color \
  'print -r -- "${DOTFILES_TEST_MISE_ACTIVATED:-no}:${DOTFILES_TEST_STARSHIP_INIT:-no}:${DOTFILES_TEST_FZF_THEME:-no}"')"
assert_eq '1:1:1' "$activated" 'present integrations must still be activated'
printf 'PASS: present integrations are activated normally\n'

# Startup itself must leave a clean status behind, or the first prompt of every
# shell reports a failure the user never caused.
env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
  XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
  XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
  DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZSHRC="$zshrc" \
  ZDOTDIR="$root/zdotdir" "$zsh_path" -f -c "
    source \"\$DOTFILES_TEST_ZSHENV\"
    source \"\$DOTFILES_TEST_ZSHRC\"
    exit
  "
printf 'PASS: startup finishes with a clean exit status\n'

# --- Completion (#157/#168) -------------------------------------------------

compinit_calls="$(grep -c '^[[:space:]]*compinit' "$zshrc" || true)"
assert_eq 1 "$compinit_calls" 'the shared profile must call compinit exactly once'
grep -Fq 'compinit -d "$ZSH_COMPDUMP"' "$zshrc" ||
  _test_die 'compinit must keep using the cached compdump'

for platform_file in \
  "$repo_root"/platforms/*/stow/zsh-platform/.config/zsh/platform.zsh \
  "$repo_root"/platforms/*/stow/zsh-platform/.config/zsh/platform-env.zsh; do
  [[ -f "$platform_file" ]] || continue
  assert_file_not_contains "$platform_file" 'compinit'
done
printf 'PASS: exactly one cached compinit across shared and platform config\n'

compdump="$(run_zsh bare xterm-256color 'print -r -- $ZSH_COMPDUMP')"
assert_eq "$root/cache/zsh/zcompdump" "$compdump" 'compdump must stay in the cache'

menu_style="$(run_zsh bare xterm-256color "zstyle -L ':completion:*' menu")"
assert_contains "$menu_style" 'menu select'
printf 'PASS: completion uses an interactive menu\n'

# --- Interactive comments (#168) --------------------------------------------

comments="$(run_zsh bare xterm-256color '[[ -o interactivecomments ]] && print -r -- on')"
assert_eq 'on' "$comments" 'INTERACTIVE_COMMENTS must be enabled'

pasted="$(run_zsh bare xterm-256color 'eval "print -r -- kept # trailing note"')"
assert_eq 'kept' "$pasted" 'a pasted inline comment must be ignored'

correct="$(run_zsh bare xterm-256color '[[ -o correct ]] && print -r -- on || print -r -- off')"
assert_eq 'off' "$correct" 'CORRECT was explicitly rejected and must stay off'
printf 'PASS: interactive comments on, spelling correction off\n'

# --- History widgets and key bindings (#168) --------------------------------

widgets="$(run_zsh bare xterm-256color 'zle -la')"
assert_contains "$widgets" 'up-line-or-beginning-search'
assert_contains "$widgets" 'down-line-or-beginning-search'

# assert_binding <term> <sequence> <widget> <label>
assert_binding() {
  local term="$1" sequence="$2" widget="$3" label="$4" resolved
  resolved="$(run_zsh bare "$term" "bindkey -- ${sequence}")"
  [[ "$resolved" == *" $widget" ]] ||
    _test_die "$label under TERM=$term resolved to '${resolved:-nothing}', expected $widget"
}

# Ghostty, Konsole, WSL and SSH all advertise xterm-like terminals; tmux and
# screen sessions advertise screen-*; a VM text console advertises linux; and a
# remote TERM the local terminfo database does not know must still work.
for term in xterm-256color screen-256color tmux-256color linux xterm-ghostty dumb; do
  assert_binding "$term" "\$'\\e[H'" beginning-of-line 'Home (xterm)'
  assert_binding "$term" "\$'\\eOH'" beginning-of-line 'Home (application)'
  assert_binding "$term" "\$'\\e[F'" end-of-line 'End (xterm)'
  assert_binding "$term" "\$'\\eOF'" end-of-line 'End (application)'
  assert_binding "$term" "\$'\\e[3~'" delete-char 'Delete'
  assert_binding "$term" "\$'\\e[1;5D'" backward-word 'Ctrl+Left (xterm)'
  assert_binding "$term" "\$'\\eOd'" backward-word 'Ctrl+Left (rxvt)'
  assert_binding "$term" "\$'\\e[1;5C'" forward-word 'Ctrl+Right (xterm)'
  assert_binding "$term" "\$'\\eOc'" forward-word 'Ctrl+Right (rxvt)'
  assert_binding "$term" "\$'\\e[A'" up-line-or-beginning-search 'Up (xterm)'
  assert_binding "$term" "\$'\\eOA'" up-line-or-beginning-search 'Up (application)'
  assert_binding "$term" "\$'\\e[B'" down-line-or-beginning-search 'Down (xterm)'
  assert_binding "$term" "\$'\\eOB'" down-line-or-beginning-search 'Down (application)'
done
printf 'PASS: editing and history keys resolve in every supported terminal mode\n'

# The terminfo sequence of a terminal that reports one is bound too, so the
# application-mode keypad the line editor enables is covered by name and not
# only by the hard-coded fallbacks.
terminfo_home="$(run_zsh bare xterm-256color '
  zmodload zsh/terminfo
  bindkey -- "${terminfo[khome]}"
')"
assert_contains "$terminfo_home" 'beginning-of-line'

# Plain Left/Right must keep moving by character: the uppercase SS3 forms are
# the arrows themselves in application-cursor mode, not Ctrl+arrow.
assert_binding xterm-256color "\$'\\eOD'" backward-char 'Left (application)'
assert_binding xterm-256color "\$'\\eOC'" forward-char 'Right (application)'
printf 'PASS: plain Left/Right are not captured by the word-motion bindings\n'

# Ctrl-R stays fzf's. The shared config must not bind it at all.
assert_file_not_contains "$zshrc" "bindkey '^R'"
ctrl_r_bare="$(run_zsh bare xterm-256color "bindkey -- '^R'")"
assert_contains "$ctrl_r_bare" 'history-incremental-search-backward'
ctrl_r_full="$(run_zsh full xterm-256color "bindkey -- '^R'")"
assert_contains "$ctrl_r_full" 'fzf-history-widget'
printf 'PASS: Ctrl-R remains owned by the fzf history workflow\n'

# --- Archive helpers (#168) -------------------------------------------------

work="$root/archives"
mkdir -p "$work/payload"
printf 'alpha\n' >"$work/payload/a.txt"
printf 'beta\n' >"$work/payload/b.txt"

archive_check() {
  local suffix="$1"
  local created="$work/created.$suffix"
  local extract_dir="$work/extract-$suffix"

  rm -rf -- "$extract_dir" "$created"
  mkdir -p "$extract_dir"
  export DOTFILES_TEST_EXTRACT="$extract_dir"

  run_capture run_zsh bare xterm-256color "
    builtin cd \"\$DOTFILES_TEST_WORK\" || exit 1
    tar created.${suffix} payload || exit 1
    builtin cd \"\$DOTFILES_TEST_EXTRACT\" || exit 1
    untar ../created.${suffix} || exit 1
  "
  assert_success
  assert_path_exists "$created"
  assert_file_contains "$extract_dir/payload/a.txt" alpha
  assert_file_contains "$extract_dir/payload/b.txt" beta
}

for suffix in tar tar.gz tar.xz tgz txz; do
  archive_check "$suffix"
done
printf 'PASS: tar/untar create and extract .tar, .tar.gz and .tar.xz\n'

# The helper must never shadow the native CLI.
listing="$(run_zsh bare xterm-256color "
  builtin cd \"\$DOTFILES_TEST_WORK\" || exit 1
  tar -tf created.tar.gz
")"
assert_contains "$listing" 'payload/a.txt'

native_listing="$(run_zsh bare xterm-256color "
  builtin cd \"\$DOTFILES_TEST_WORK\" || exit 1
  command tar -tf created.tar.gz
")"
assert_eq "$native_listing" "$listing" 'tar -tf must behave like command tar -tf'

run_capture run_zsh bare xterm-256color 'tar --help'
assert_success
assert_contains "$TEST_OUTPUT" 'tar'

run_capture run_zsh bare xterm-256color "
  builtin cd \"\$DOTFILES_TEST_WORK\" || exit 1
  rm -rf option-extract && mkdir option-extract && builtin cd option-extract &&
    tar -xf ../created.tar.gz
"
assert_success
assert_path_exists "$work/option-extract/payload/a.txt"

# A single argument is not the create shorthand; it must reach the real tar.
run_capture run_zsh bare xterm-256color "
  builtin cd \"\$DOTFILES_TEST_WORK\" || exit 1
  tar only-one.tar.gz
"
assert_failure

run_capture run_zsh bare xterm-256color 'untar'
assert_status 2
assert_contains "$TEST_OUTPUT" 'usage: untar'

run_capture run_zsh bare xterm-256color "untar \"\$DOTFILES_TEST_WORK/missing.tar.gz\""
assert_failure

# untar must call the real tar, not re-enter the helper.
grep -Fq "command tar -xf" "$zshrc" ||
  _test_die 'untar must invoke command tar'
printf 'PASS: the native tar CLI is preserved in full\n'

# --- Initialization order ---------------------------------------------------

platform_line="$(grep -n 'zsh/platform.zsh' "$zshrc" | tail -n1 | cut -d: -f1)"
starship_line="$(grep -n 'starship init zsh' "$zshrc" | tail -n1 | cut -d: -f1)"
((platform_line > starship_line)) ||
  _test_die 'platform.zsh (syntax highlighting) must stay after the prompt'

for platform_file in "$repo_root"/platforms/*/stow/zsh-platform/.config/zsh/platform.zsh; do
  [[ -f "$platform_file" ]] || continue
  grep -Fq 'zsh-syntax-highlighting' "$platform_file" || continue
  highlighting_line="$(grep -n 'zsh-syntax-highlighting' "$platform_file" | tail -n1 | cut -d: -f1)"
  suggestions_line="$(grep -n 'zsh-autosuggestions' "$platform_file" | tail -n1 | cut -d: -f1)"
  ((highlighting_line > suggestions_line)) ||
    _test_die "syntax highlighting must be initialized last in $platform_file"
done
printf 'PASS: syntax highlighting stays last in the initialization order\n'

# --- Coexistence with the Parrot globbing policy (#167/#168) ----------------
#
# Parrot's platform.zsh unsets NOMATCH so unmatched CTF payload patterns reach
# the tool. #168 must not redefine that policy, and its helpers must keep
# working underneath it.
parrot_zsh="$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh"
assert_file_not_contains "$zshrc" 'NOMATCH'
assert_file_not_contains "$zshrc" 'noglob'

parrot_state="$(
  env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
    DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZSHRC="$zshrc" \
    DOTFILES_TEST_PLATFORM_ENV="$parrot_zsh" \
    "$zsh_path" -f -c "
      source \"\$DOTFILES_TEST_ZSHENV\"
      source \"\$DOTFILES_TEST_ZSHRC\"
      source \"\$DOTFILES_TEST_PLATFORM_ENV\"
      [[ -o nomatch ]] && print -r -- nomatch-on || print -r -- nomatch-off
      print -r -- \${\$(whence -w tar)#tar: }
      print -r -- \${\$(whence -w untar)#untar: }
      bindkey -- \$'\\e[1;5C'
      print -r -- https://target.invalid/FUZZ?id=*
    "
)"
assert_contains "$parrot_state" 'nomatch-off'
assert_contains "$parrot_state" 'function'
assert_contains "$parrot_state" 'forward-word'
assert_contains "$parrot_state" 'https://target.invalid/FUZZ?id=*'
printf 'PASS: shared helpers and bindings coexist with the Parrot glob policy\n'

printf 'Shared Zsh startup, PATH and ergonomics tests passed.\n'
