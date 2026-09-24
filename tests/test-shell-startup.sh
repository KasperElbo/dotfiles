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
zprofile="$repo_root/zsh/.config/zsh/.zprofile"

sandbox_bin="$root/sandbox-bin"
tool_bin="$root/tool-bin"
# Claude Code is mise-owned, so it lives here and nowhere else: it becomes
# reachable only once `mise activate` has run, which is late in .zshrc.
mise_shims="$root/mise-shims"
mkdir -p "$sandbox_bin" "$tool_bin" "$mise_shims" "$root/config/fzf/themes"

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
# mise activation is what puts mise-managed tools on PATH, and that is the
# whole point for anything the AI profile installs through the npm backend. A
# fake that only sets a marker would let a gate that runs before activation
# pass here and fail on every real machine, so this one prepends the shims
# directory the way the real `mise activate zsh` output does.
cat >"$tool_bin/mise" <<EOF
#!/usr/bin/env bash
# Only activation. Answering every argv with the activation script would let a
# startup file ask this fixture anything at all and be handed shell code to
# eval, so the one call this stub models is the one it accepts.
if [[ "\${1:-}" != activate ]]; then
  printf 'strict mise fixture rejected unsupported argv:' >&2
  printf ' %q' "\$@" >&2
  printf '\n' >&2
  exit 96
fi
printf 'export DOTFILES_TEST_MISE_ACTIVATED=1\n'
printf 'export PATH=%q:\$PATH\n' "$mise_shims"
EOF
cat >"$tool_bin/starship" <<'EOF'
#!/usr/bin/env bash
printf 'export DOTFILES_TEST_STARSHIP_INIT=1\n'
EOF
# The real `fzf --zsh` binds Ctrl-R to its own history widget and Alt-C, which
# the terminal sends as ESC c, to its directory picker.
cat >"$tool_bin/fzf" <<'EOF'
#!/usr/bin/env bash
cat <<'ZSH'
fzf-history-widget() { :; }
zle -N fzf-history-widget
bindkey '^R' fzf-history-widget
fzf-cd-widget() { :; }
zle -N fzf-cd-widget
bindkey '\ec' fzf-cd-widget
ZSH
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$tool_bin/eza"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tool_bin/bat"
chmod +x "$tool_bin"/*
printf '#!/usr/bin/env bash\nexit 0\n' >"$mise_shims/claude"
chmod +x "$mise_shims/claude"

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
# shellcheck disable=SC2016 # $path belongs to the child Zsh process.
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

# A macOS *login* shell, which is the ordinary shape there: zsh is the
# registered login shell and terminals start login shells. The order is
# .zshenv, then /etc/zprofile, then .zshrc -- and /etc/zprofile runs
# path_helper, which rebuilds PATH from /etc/paths and /etc/paths.d with the
# system directories in front and everything that was already there after
# them. Anything .zshenv prepended is demoted, so the startup files have to
# re-assert the policy after every system file has had its say.
#
# path_helper is simulated rather than invoked: it does not exist on Linux, and
# what matters is its effect on the order, not its implementation.
macos_login_path="$(
  env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
    DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZSHRC="$zshrc" \
    DOTFILES_TEST_PLATFORM_ENV="$macos_env" \
    "$zsh_path" -f -c '
      source "$DOTFILES_TEST_ZSHENV"
      source "$DOTFILES_TEST_PLATFORM_ENV"
      # /etc/zprofile: the system directories from /etc/paths first, then
      # every entry that was already on PATH, in order. `path` is unique, so
      # the duplicates this creates collapse exactly as path_helper drops them.
      path=(/usr/local/bin /usr/bin /bin /usr/sbin /sbin $path)
      export PATH
      source "$DOTFILES_TEST_ZSHRC"
      print -l -- $path
    '
)"
assert_eq "$root/home/.local/bin" \
  "$(printf '%s\n' "$macos_login_path" | head -n1)" \
  'user executables must keep the front of PATH in a macOS login shell, after path_helper has reordered it'
assert_eq '/opt/homebrew/opt/coreutils/libexec/gnubin' \
  "$(printf '%s\n' "$macos_login_path" | tail -n1)" \
  'macOS gnubin must stay last in a login shell too'
login_duplicates="$(printf '%s\n' "$macos_login_path" | sort | uniq -d)"
[[ -z "$login_duplicates" ]] || {
  printf 'TEST FAILURE: the login shape duplicated PATH entries:\n%s\n' \
    "$login_duplicates" >&2
  exit 1
}
printf 'PASS: a macOS login shell keeps ~/.local/bin first after path_helper\n'

# --- A login that is not interactive gets mise's shims -----------------------
#
# mise is activated in .zshrc, which only an interactive shell reads, so a
# login that is not interactive -- `zsh -lc`, and everything started through
# one -- used to run whatever the system had under a mise-owned name. On a real
# Fedora machine python, node and tree-sitter are all in /usr/bin, so the
# verifier's non-interactive login probe failed every one of them (real-install
# run 35924092083). The zsh package's .zprofile puts mise's shims directory on
# PATH for every login, behind ~/.local/bin and ahead of the system.
#
# These run a real `zsh -l`: a home carrying the package's two top-level files
# the way Stow links them, and nothing else of ours. The host's own
# /etc/zshenv and /etc/zprofile take part, as they do on a machine, so only the
# entries this fixture controls are compared -- never the whole PATH, which
# macOS's path_helper reorders.
login_home="$root/login-home"
login_data="$root/login-data"
login_system="$root/login-system-bin"
login_shims="$login_data/mise/shims"
mkdir -p "$login_home/.config/zsh" "$login_home/.local/bin" "$login_system" "$login_shims"
ln -s "$zshenv" "$login_home/.zshenv"
ln -s "$zprofile" "$login_home/.config/zsh/.zprofile"
# The system's copy and mise's shim of the same two runtimes. Each only says
# which one it is, so a resolution that picked the other cannot pass.
for runtime in python node; do
  printf '#!/bin/sh\nprintf "system %s\\n"\n' "$runtime" >"$login_system/$runtime"
  printf '#!/bin/sh\nprintf "mise %s\\n"\n' "$runtime" >"$login_shims/$runtime"
done
chmod +x "$login_system"/* "$login_shims"/*

# run_login <zsh flags> <script> [VAR=value...]: a fresh Zsh started the way a
# login is, from nothing but this fixture's environment. The system directory
# is part of the PATH it inherits, which is where a login finds /usr/bin.
run_login() {
  local flags="$1" script="$2"
  shift 2
  env -i HOME="$login_home" XDG_DATA_HOME="$login_data" \
    XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" \
    TERM=xterm-256color PATH="$login_system:$sandbox_bin" "$@" \
    "$zsh_path" "$flags" "$script"
}

# shellcheck disable=SC2016 # Expanded by the child Zsh.
resolved="$(run_login -lc 'command -v python; command -v node; python; node')"
assert_eq "$login_shims/python
$login_shims/node
mise python
mise node" "$resolved" 'a login that is not interactive must run mise'"'"'s shims, not the system copies'
printf 'PASS: a login that is not interactive resolves python and node to the mise shims\n'

# Behind ~/.local/bin, ahead of the system directory it inherited.
# shellcheck disable=SC2016 # Expanded by the child Zsh.
login_order="$(run_login -lc 'print -l -- $path' |
  grep -Fx -e "$login_home/.local/bin" -e "$login_shims" -e "$login_system" |
  paste -sd: -)"
assert_eq "$login_home/.local/bin:$login_shims:$login_system" "$login_order" \
  'login PATH order of ~/.local/bin, the mise shims and the system directory'
printf 'PASS: the shims sit behind ~/.local/bin and ahead of the system directories\n'

# mise's data directory is resolved the way mise resolves it: MISE_DATA_DIR
# first, then XDG_DATA_HOME.
relocated="$root/relocated-mise"
mkdir -p "$relocated/shims"
cp "$login_shims/python" "$relocated/shims/python"
# shellcheck disable=SC2016 # Expanded by the child Zsh.
resolved="$(run_login -lc 'command -v python' "MISE_DATA_DIR=$relocated")"
assert_eq "$relocated/shims/python" "$resolved" 'MISE_DATA_DIR must decide where the shims are'
printf 'PASS: the shims directory follows MISE_DATA_DIR\n'

# MISE_SHIMS_DIR names the shims directory outright, and wins over
# MISE_DATA_DIR, which is the precedence check_mise_owned in
# common/lib/verify.sh applies. Dropping it from .zprofile passed every suite
# while a machine that sets it had the shell and the verifier looking in two
# places, and the verifier telling the user to restow a .zprofile that was
# linked and working (#539, V5-12).
explicit_shims="$root/explicit-shims"
mkdir -p "$explicit_shims"
printf '#!/bin/sh\nprintf "explicit python\\n"\n' >"$explicit_shims/python"
chmod +x "$explicit_shims/python"
# shellcheck disable=SC2016 # Expanded by the child Zsh.
resolved="$(run_login -lc 'command -v python' "MISE_SHIMS_DIR=$explicit_shims")"
assert_eq "$explicit_shims/python" "$resolved" 'MISE_SHIMS_DIR must decide where the shims are'
# shellcheck disable=SC2016 # Expanded by the child Zsh.
resolved="$(run_login -lc 'command -v python' "MISE_SHIMS_DIR=$explicit_shims" "MISE_DATA_DIR=$relocated")"
assert_eq "$explicit_shims/python" "$resolved" 'MISE_SHIMS_DIR must win over MISE_DATA_DIR'
printf 'PASS: MISE_SHIMS_DIR names the shims directory, ahead of MISE_DATA_DIR\n'

# The startup benchmark measures what a terminal pays, which is a login shell:
# .zprofile included. It measured `zsh -i` alone and called that the terminal's
# cost, so anything added to .zprofile was invisible to it (#539, V5-13). Each
# startup file here records that it ran; one run per shape must read .zprofile
# exactly once, from the interactive login, and .zshrc twice.
bench_home="$root/bench-home"
bench_log="$root/bench.log"
mkdir -p "$bench_home"
: >"$bench_log"
printf 'print -r -- zshenv >>"$BENCH_LOG"\n' >"$bench_home/.zshenv"
printf 'print -r -- zprofile >>"$BENCH_LOG"\n' >"$bench_home/.zprofile"
printf 'print -r -- zshrc >>"$BENCH_LOG"\n' >"$bench_home/.zshrc"
run_capture env -i HOME="$bench_home" BENCH_LOG="$bench_log" TERM=dumb \
  PATH="$(dirname "$zsh_path"):$sandbox_bin" \
  "$repo_root/scripts/benchmark-shell-startup.sh" --runs 1
assert_success
assert_contains "$TEST_OUTPUT" 'interactive-login  runs=1'
assert_eq '3 1 2' "$(grep -cx zshenv "$bench_log") $(grep -cx zprofile "$bench_log") $(grep -cx zshrc "$bench_log")" \
  'one run of each shape reads .zshenv three times, .zprofile once and .zshrc twice'
printf 'PASS: the startup benchmark measures the login shell a terminal starts\n'

# A machine without mise's shims directory is left alone: nothing is added,
# the system copy is what runs, and startup stays silent and clean.
mv "$login_shims" "$root/withheld-login-shims"
# shellcheck disable=SC2016 # Expanded by the child Zsh.
run_capture run_login -lc 'command -v python; print -l -- $path'
assert_success
assert_eq "$login_system/python" "$(printf '%s\n' "$TEST_OUTPUT" | head -n1)" \
  'with no shims directory the login must fall through to the system copy'
assert_not_contains "$TEST_OUTPUT" "$login_shims"
assert_not_contains "$TEST_OUTPUT" 'no such file'
mv "$root/withheld-login-shims" "$login_shims"
printf 'PASS: a login on a machine with no mise shims directory adds nothing and stays quiet\n'

# .zprofile is read by login shells only. A plain `zsh -c` script keeps the
# PATH it was given, exactly as before.
# shellcheck disable=SC2016 # Expanded by the child Zsh.
resolved="$(run_login -c 'command -v python')"
assert_eq "$login_system/python" "$resolved" 'a Zsh that is not a login must not read .zprofile'
printf 'PASS: a Zsh that is not a login is unaffected\n'

# The macOS order. A login reads .zshenv, then /etc/zprofile, whose
# path_helper rebuilds PATH with the /etc/paths and /etc/paths.d directories in
# front of everything .zshenv set -- Homebrew's /opt/homebrew/bin included --
# and only then $ZDOTDIR/.zprofile. After .zprofile a login that is not
# interactive reads only /etc/zlogin and $ZDOTDIR/.zlogin; macOS ships no
# /etc/zlogin and this repository tracks no .zlogin, so what .zprofile puts in
# front is what that login runs.
#
# The macOS real-install job showed what sits in front there: node and npm
# from /opt/homebrew/bin, dotnet from /usr/local/bin, and python from a
# /Library/Frameworks/Python.framework directory the runner image registers
# with path_helper, ahead of the rest. path_helper is simulated as the macOS
# login case above simulates it, with a directory it puts first carrying its
# own copy of every one of those runtimes, and a /usr/local/bin stand-in
# behind it. Without .zprofile that first directory wins; with it, the shims do.
macos_first="$root/macos-paths-d-bin"
macos_usr_local="$root/macos-usr-local-bin"
macos_shims="$root/data/mise/shims"
mkdir -p "$macos_first" "$macos_usr_local" "$macos_shims"
for runtime in python node npm dotnet; do
  for directory in "$macos_first" "$macos_usr_local" "$macos_shims"; do
    printf '#!/bin/sh\nexit 0\n' >"$directory/$runtime"
    chmod +x "$directory/$runtime"
  done
done

# macos_login <with-zprofile|without-zprofile>: the non-interactive login's
# resolution of each runtime, then its PATH.
macos_login() {
  env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" TERM=xterm-256color PATH="$sandbox_bin" \
    DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZPROFILE="$zprofile" \
    DOTFILES_TEST_PLATFORM_ENV="$macos_env" \
    DOTFILES_TEST_PATHS_FIRST="$macos_first" \
    DOTFILES_TEST_USR_LOCAL="$macos_usr_local" \
    DOTFILES_TEST_MODE="$1" \
    "$zsh_path" -f -c '
      source "$DOTFILES_TEST_ZSHENV"
      source "$DOTFILES_TEST_PLATFORM_ENV"
      # /etc/zprofile: the path_helper directories first, then every entry that
      # was already on PATH, in order.
      path=("$DOTFILES_TEST_PATHS_FIRST" "$DOTFILES_TEST_USR_LOCAL" /usr/bin /bin /usr/sbin /sbin $path)
      export PATH
      [[ "$DOTFILES_TEST_MODE" != with-zprofile ]] || source "$DOTFILES_TEST_ZPROFILE"
      for runtime in python node npm dotnet; do
        print -r -- "$runtime=${commands[$runtime]}"
      done
      print -l -- $path
    '
}

macos_before="$(macos_login without-zprofile)"
for runtime in python node npm dotnet; do
  assert_contains "$macos_before" "$runtime=$macos_first/$runtime"
done
printf 'PASS: without .zprofile, a macOS login that is not interactive runs what path_helper puts first\n'

macos_after="$(macos_login with-zprofile)"
for runtime in python node npm dotnet; do
  assert_contains "$macos_after" "$runtime=$macos_shims/$runtime"
done
macos_after_path="$(printf '%s\n' "$macos_after" | grep -v '=')"
assert_eq "$root/home/.local/bin
$macos_shims
$macos_first
$macos_usr_local" "$(printf '%s\n' "$macos_after_path" | head -n4)" \
  'a macOS login that is not interactive must keep ~/.local/bin and the shims ahead of path_helper'"'"'s directories'
assert_eq '/opt/homebrew/opt/coreutils/libexec/gnubin' \
  "$(printf '%s\n' "$macos_after_path" | tail -n1)" \
  'macOS gnubin must stay last in a login that is not interactive'
macos_duplicates="$(printf '%s\n' "$macos_after_path" | sort | uniq -d)"
[[ -z "$macos_duplicates" ]] ||
  _test_die "the macOS login duplicated PATH entries: $macos_duplicates"
rm -r -- "$macos_first" "$macos_usr_local"
rm -f -- "$macos_shims"/*
printf 'PASS: a macOS login that is not interactive runs the shims ahead of path_helper'"'"'s directories\n'

# An interactive login reads .zprofile and then .zshrc, and mise activation in
# .zshrc still decides what runs: the fake's activation directory (the stand-in
# for mise's install directories) leads, ~/.local/bin follows, and the shims
# only after it. Sourced three times, nothing is duplicated or moved.
# shellcheck disable=SC2016 # $path belongs to the child Zsh process.
interactive_login_path() {
  env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" TERM=xterm-256color \
    PATH="$tool_bin:$sandbox_bin" \
    DOTFILES_TEST_ZSHENV="$zshenv" DOTFILES_TEST_ZPROFILE="$zprofile" \
    DOTFILES_TEST_ZSHRC="$zshrc" \
    "$zsh_path" -f -c "
      repeat $1; do
        source \"\$DOTFILES_TEST_ZSHENV\"
        source \"\$DOTFILES_TEST_ZPROFILE\"
        source \"\$DOTFILES_TEST_ZSHRC\"
      done
      print -l -- \$path
    "
}
interactive_once="$(interactive_login_path 1)"
assert_eq "$interactive_once" "$(interactive_login_path 3)" \
  'repeated login startup changed PATH'
assert_eq "$mise_shims
$root/home/.local/bin
$root/data/mise/shims" "$(printf '%s\n' "$interactive_once" | head -n3)" \
  'mise activation must still lead an interactive login, ahead of ~/.local/bin and the shims'
interactive_duplicates="$(printf '%s\n' "$interactive_once" | sort | uniq -d)"
[[ -z "$interactive_duplicates" ]] ||
  _test_die "login startup duplicated PATH entries: $interactive_duplicates"
rmdir "$root/data/mise/shims"
printf 'PASS: an interactive login still resolves through mise activation first\n'

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

# shellcheck disable=SC2016 # The child Zsh reads these, not this shell.
activated="$(run_zsh full xterm-256color \
  'print -r -- "${DOTFILES_TEST_MISE_ACTIVATED:-no}:${DOTFILES_TEST_STARSHIP_INIT:-no}:${DOTFILES_TEST_FZF_THEME:-no}"')"
assert_eq '1:1:1' "$activated" 'present integrations must still be activated'
printf 'PASS: present integrations are activated normally\n'

# --- Claude Code alias ------------------------------------------------------
#
# The alias has to earn its place twice: the `ai` capability must be installed,
# and Claude Code must actually be on PATH. Either one missing leaves the
# shell without it.
#
# Claude Code is reachable here only through the mise shims directory that the
# `mise` fake puts on PATH when .zshrc activates it, which is what a real
# machine looks like. That is deliberate: the gate used to sit with the other
# aliases, ~100 lines above `mise activate`, so `command -v claude` answered
# "absent" everywhere and the alias was never defined.

install_state="$root/state/dotfiles/install.conf"
mkdir -p "${install_state%/*}"

write_install_state() {
  printf 'schema_version=2\nprofile=install\nstatus=installed\n' >"$install_state"
  printf 'requested_capabilities=base,ai\nobserved_capabilities=%s\n' "$1" \
    >>"$install_state"
}

run_capture run_zsh full xterm-256color 'alias claude-unsafe'
assert_status 1
printf 'PASS: claude-unsafe is undefined when no install state was ever written\n'

# Requested but not observed: asking for the capability is not having it.
write_install_state base
run_capture run_zsh full xterm-256color 'alias claude-unsafe'
assert_status 1
printf 'PASS: claude-unsafe is undefined when the ai capability is not installed\n'

write_install_state base,ai
run_capture run_zsh full xterm-256color 'alias claude-unsafe'
assert_success
assert_eq "claude-unsafe='claude --dangerously-skip-permissions'" "$TEST_OUTPUT" \
  'the permission-bypass alias carries exactly the one flag it is named for'
printf 'PASS: claude-unsafe starts Claude Code where the ai capability is installed\n'

# The bypass is visible at the point of use (#503): the short, ordinary-looking
# `cld` it used to be called is gone, not kept alongside as a second spelling.
run_capture run_zsh full xterm-256color 'alias cld'
assert_status 1
printf 'PASS: no short alias starts Claude Code with permission prompts disabled\n'

# The regression itself, stated as its own assertion: the only claude on this
# machine arrives with mise, so a gate asked before activation cannot see it.
resolved="$(run_zsh full xterm-256color 'command -v claude')"
assert_eq "$mise_shims/claude" "$resolved" \
  'claude must be reachable only through the mise shims directory'
printf 'PASS: the alias is decided after mise has put Claude Code on PATH\n'

# Recorded, then removed by hand: an alias that resolves to nothing is worse
# than no alias.
mv "$mise_shims/claude" "$mise_shims/claude.removed"
run_capture run_zsh full xterm-256color 'alias claude-unsafe'
assert_status 1
printf 'PASS: claude-unsafe is undefined when Claude Code is gone from PATH\n'
mv "$mise_shims/claude.removed" "$mise_shims/claude"

# No mise at all: nothing activates, so nothing reaches the shims directory.
run_capture run_zsh bare xterm-256color 'alias claude-unsafe'
assert_status 1
printf 'PASS: claude-unsafe is undefined when mise never activated\n'

rm -f "$install_state"

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
# shellcheck disable=SC2016 # Matching the literal text in .zshrc.
grep -Fq 'compinit -d "$ZSH_COMPDUMP"' "$zshrc" ||
  _test_die 'compinit must keep using the cached compdump'

for platform_file in \
  "$repo_root"/platforms/*/stow/zsh-platform/.config/zsh/platform.zsh \
  "$repo_root"/platforms/*/stow/zsh-platform/.config/zsh/platform-env.zsh; do
  [[ -f "$platform_file" ]] || continue
  assert_file_not_contains "$platform_file" 'compinit'
done
printf 'PASS: exactly one cached compinit across shared and platform config\n'

# shellcheck disable=SC2016 # $ZSH_COMPDUMP belongs to the child Zsh process.
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
# shellcheck disable=SC2016 # $terminfo belongs to the child Zsh process.
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

# Alt-C is fzf's too, and is the one shared binding whose physical key differs
# per platform: on macOS the terminal has to send Left Option as Meta for this
# same ESC c to arrive (#257). The shared configuration stays platform-neutral
# and must not rebind it for any platform.
alt_c_full="$(run_zsh full xterm-256color "bindkey -- '\ec'")"
assert_contains "$alt_c_full" 'fzf-cd-widget'
printf 'PASS: Alt-C remains owned by the fzf directory picker\n'

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

# #168 asks for .tar, .tar.gz and .tar.xz "where supported by the platform tar
# implementation". tar and gzip are assumed; a suffix whose compressor is not
# installed is reported as skipped rather than failing or passing silently.
command -v tar >/dev/null 2>&1 ||
  _test_die 'tar is required for the archive helper tests'

covered=()
skipped_suffixes=()
for suffix in tar tar.gz tar.xz tgz txz; do
  case "$suffix" in
  tar.gz | tgz) compressor=gzip ;;
  tar.xz | txz) compressor=xz ;;
  *) compressor="" ;;
  esac

  if [[ -n "$compressor" ]] && ! command -v "$compressor" >/dev/null 2>&1; then
    skipped_suffixes+=(".$suffix (no $compressor)")
    continue
  fi

  archive_check "$suffix"
  covered+=(".$suffix")
done

covered_suffixes="$(printf '%s\n' "${covered[@]}")"
for required in .tar .tar.gz; do
  grep -Fxq -- "$required" <<<"$covered_suffixes" ||
    _test_die "the archive helpers must be exercised for $required"
done

printf 'PASS: tar/untar round-trip %s\n' "${covered[*]}"
((${#skipped_suffixes[@]} == 0)) ||
  printf 'SKIP: no compressor installed for %s\n' "${skipped_suffixes[*]}"

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

# --- The theme wrapper's exit-status handling (#148) ------------------------
#
# `theme` exits 3 when the shared theme state is current but an independent
# platform action failed. This shell's own theming is correct in that case, so
# the wrapper must still refresh; any other failure must not restart the shell
# and hide it.
theme_wrapper="$(run_zsh bare xterm-256color 'whence -v theme; functions theme')"
assert_contains "$theme_wrapper" 'theme_status == 3'

fake_theme_bin="$root/fake-theme-bin"
mkdir -p "$fake_theme_bin"
cat >"$fake_theme_bin/theme" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_THEME_EXIT:-0}"
EOF
chmod +x "$fake_theme_bin/theme"

# exec zsh would replace the test shell, so the wrapper is exercised with a
# stub exec that reports instead of replacing.
theme_wrapper_result() {
  env -i \
    HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_DATA_HOME="$root/data" \
    XDG_STATE_HOME="$root/state" \
    XDG_CACHE_HOME="$root/cache" \
    TERM=xterm-256color \
    PATH="$fake_theme_bin:$sandbox_bin" \
    FAKE_THEME_EXIT="$1" \
    DOTFILES_TEST_ZSHENV="$zshenv" \
    DOTFILES_TEST_ZSHRC="$zshrc" \
    "$zsh_path" -f -c "
      source \"\$DOTFILES_TEST_ZSHENV\"
      source \"\$DOTFILES_TEST_ZSHRC\"
      exec() { print -r -- refreshed }
      theme mocha
      print -r -- \"status=\$?\"
    "
}

assert_contains "$(theme_wrapper_result 0)" refreshed
assert_contains "$(theme_wrapper_result 3)" refreshed
partial="$(theme_wrapper_result 1)"
assert_not_contains "$partial" refreshed
assert_contains "$partial" 'status=1'
printf 'PASS: the theme wrapper refreshes on a partial apply but not on a failure\n'

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
