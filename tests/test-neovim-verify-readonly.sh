#!/usr/bin/env bash
set -uo pipefail

# Verification starts the real Neovim configuration to prove it loads. That
# start used to repair what it was inspecting: on a machine whose plugin tree
# was incomplete, simply starting Neovim installed the missing plugins and then
# the verifier credited the state it had just created. Because
# stdpath("config") is the stowed symlink into this checkout, Lazy also rewrote
# the tracked lazy-lock.json to branch tips (issue #371).
#
# DOTFILES_NVIM_VERIFY=1 is the answer: no bootstrap clone, no installing of
# missing plugins, no generated help tags or README copies. This suite holds
# that mode to "changes nothing", and holds the failed-clone path to
# terminating instead of blocking on getchar().
#
# Every case here is offline. Nothing in this suite may reach the network, so a
# machine that cannot clone is a supported fixture rather than a skip.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

lazyvim_config="$repo_root/nvim-lazyvim/.config/nvim"
tracked_lock="$lazyvim_config/lazy-lock.json"

# Prerequisites fail loudly and name themselves. A suite that quietly skips
# when its prerequisite is absent reports a clean machine it never looked at,
# which is the defect class this repository keeps finding.
command -v nvim >/dev/null 2>&1 ||
  { printf 'nvim is required to start the real configuration\n' >&2; exit 1; }

# The same checkout .github/workflows/validate.yml prepares at the commit
# lazy-lock.json pins. Lazy has to be real: a stub would let the "writes
# nothing" assertions pass against a configuration that never ran.
lazy_nvim="${DOTFILES_LAZY_NVIM:-${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/lazy.nvim}"
[[ -d "$lazy_nvim/lua/lazy" ]] ||
  { printf 'lazy.nvim is required; set DOTFILES_LAZY_NVIM to a checkout (looked in %s)\n' \
    "$lazy_nvim" >&2; exit 1; }

# The tracked lock file is the thing the defect rewrote, so restoring it is the
# suite's own responsibility even if an assertion aborts partway.
lock_backup="$(mktemp)"
cp -- "$tracked_lock" "$lock_backup"
restore_tracked_lock() {
  cp -- "$lock_backup" "$tracked_lock"
  rm -f -- "$lock_backup"
}
test_install_cleanup_trap restore_tracked_lock

# A git that refuses to clone and passes everything else through. This is what
# keeps the suite offline: the bootstrap path is exercised for real, and its
# failure is the failure a machine without network sees.
install_offline_git() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/git" <<EOF_GIT
#!/usr/bin/env bash
for argument in "\$@"; do
  if [[ "\$argument" == clone ]]; then
    printf '%s\n' "\$*" >>"\${GIT_CLONE_LOG:?}"
    printf 'fatal: unable to access: Could not resolve host\n' >&2
    exit 128
  fi
done
exec $(type -P git) "\$@"
EOF_GIT
  chmod +x "$bin/git"
}

# config_mode "link" reproduces what common/stow.sh deploys, so a write through
# stdpath("config") lands on the tracked file and the assertion about it is a
# real one. config_mode "copy" is for the negative controls, which deliberately
# let the old repairing behaviour run: pointed at the checkout they would dirty
# it, and a suite that damages the tree it is testing is not a control.
new_fixture() {
  local config_mode="$1"
  local with_lazy="$2"

  test_new_root
  local root="$TEST_ROOT"
  mkdir -p "$root/data/nvim/lazy" "$root/bin"
  if [[ "$with_lazy" == with-lazy ]]; then
    cp -a -- "$lazy_nvim" "$root/data/nvim/lazy/lazy.nvim"
  fi
  if [[ "$config_mode" == link ]]; then
    ln -s -- "$lazyvim_config" "$root/config/nvim"
  else
    cp -r -- "$lazyvim_config" "$root/config/nvim"
  fi
  install_offline_git "$root/bin"
  printf '%s\n' "$root"
}

# Start Neovim exactly as a platform verifier does, always bounded. The bound
# is the point of one of the cases below, so it is never left to the caller.
nvim_start_bound=60
start_nvim() {
  local root="$1"
  shift
  local -a env_args=()
  mapfile -t env_args < <(test_env_args "$root")
  run_capture env "${env_args[@]}" \
    PATH="$root/bin:$PATH" \
    GIT_CLONE_LOG="$root/logs/git-clone.log" \
    "$@" \
    timeout --kill-after=5s "${nvim_start_bound}s" \
    nvim --headless '+lua vim.cmd("qa")' +qa
}

# Only files, and only below the two roots the issue names. A directory mtime
# moves when a temporary file is created and removed again, which is not a
# change to the machine; a file that appeared or changed is.
written_below() {
  local marker="$1"
  shift
  local path
  for path in "$@"; do
    [[ -e "$path" ]] || continue
    find "$path" -type f -newer "$marker" -print
  done
}

printf 'Verify mode leaves a healthy machine untouched\n'
root="$(new_fixture link with-lazy)"
lock_before="$(md5sum "$tracked_lock")"
marker="$root/marker"
touch "$marker"
sleep 1
start_nvim "$root" DOTFILES_NVIM_VERIFY=1
assert_status 0
assert_eq '' "$(written_below "$marker" "$root/data" "$root/config/nvim/")" \
  'verify mode must not write below XDG_DATA_HOME or XDG_CONFIG_HOME'
assert_eq "$lock_before" "$(md5sum "$tracked_lock")" \
  'verify mode must not rewrite the tracked lazy-lock.json'
assert_path_missing "$root/logs/git-clone.log"

# The control for the case above: the same fixture, same offline git, only the
# flag removed. It must write, or "writes nothing" is a claim about a
# configuration that does nothing.
printf 'Without the flag the same start installs and writes\n'
root="$(new_fixture copy with-lazy)"
marker="$root/marker"
touch "$marker"
sleep 1
start_nvim "$root"
assert_path_exists "$root/logs/git-clone.log"
assert_file_contains "$root/logs/git-clone.log" 'lazy/LazyVim'
[[ -n "$(written_below "$marker" "$root/data")" ]] ||
  _test_die 'control: an unflagged start must write below XDG_DATA_HOME'

printf 'Verify mode reports a missing lazy.nvim instead of cloning it\n'
root="$(new_fixture link without-lazy)"
lock_before="$(md5sum "$tracked_lock")"
marker="$root/marker"
touch "$marker"
sleep 1
start_nvim "$root" DOTFILES_NVIM_VERIFY=1
assert_failure
assert_contains "$TEST_OUTPUT" 'lazy.nvim is not installed'
assert_contains "$TEST_OUTPUT" "$root/data/nvim/lazy/lazy.nvim"
assert_path_missing "$root/logs/git-clone.log"
assert_eq '' "$(written_below "$marker" "$root/data" "$root/config/nvim/")" \
  'a missing lazy.nvim must not be filled in'
assert_eq "$lock_before" "$(md5sum "$tracked_lock")" \
  'a missing lazy.nvim must not rewrite the tracked lazy-lock.json'

# Control for the case above: without the flag the very same fixture does try
# to clone, so the assertion that verify mode did not is about the flag.
printf 'Without the flag a missing lazy.nvim is cloned\n'
root="$(new_fixture copy without-lazy)"
start_nvim "$root"
assert_path_exists "$root/logs/git-clone.log"
assert_file_contains "$root/logs/git-clone.log" 'lazy.nvim'

# The hang. vim.fn.getchar() blocks forever without a UI, on any stdin -- an
# open pipe and /dev/null both reproduced it -- and Fedora's verifier applied
# no timeout at all, so the run never ended. Both stdin shapes are asserted
# because the obvious fix, "headless means stdin is closed", is wrong.
printf 'A failed bootstrap clone terminates headlessly on any stdin\n'
for stdin_shape in devnull pipe; do
  root="$(new_fixture copy without-lazy)"
  started="$SECONDS"
  case "$stdin_shape" in
    devnull) start_nvim "$root" </dev/null ;;
    pipe)
      fifo="$root/stdin.fifo"
      mkfifo "$fifo"
      exec 9<>"$fifo"
      start_nvim "$root" <&9
      exec 9>&-
      ;;
  esac
  elapsed=$((SECONDS - started))
  # 124 and 137 are timeout(1) giving up, which is the hang this case exists
  # to catch. The configuration must exit on its own.
  assert_failure
  [[ "$TEST_STATUS" != 124 && "$TEST_STATUS" != 137 ]] ||
    _test_die "stdin=$stdin_shape: the failed clone hung and was killed after ${elapsed}s"
  assert_contains "$TEST_OUTPUT" 'Failed to clone lazy.nvim'
done

printf 'Neovim verify-mode read-only checks passed.\n'
