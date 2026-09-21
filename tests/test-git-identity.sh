#!/usr/bin/env bash
# Hermetic machine-local Git identity migration (#163).
#
# Every scenario below builds the exact history or backup state it needs in a
# temporary directory. Nothing here reads this repository's own history, so the
# suite behaves identically in a full clone, a shallow clone, and an exported
# tarball with no .git at all.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# --- Fixtures --------------------------------------------------------------

# The identity content used by every positive fixture. It is synthetic; the
# point of the assertions below is that it never reaches a log, only a file.
identity_name="Fixture User"
identity_email="fixture@example.invalid"
identity_content=$'[user]\n\tname = '"$identity_name"$'\n\temail = '"$identity_email"$'\n'

# assert_identical <path>: the file holds exactly the fixture identity bytes.
assert_identical() {
  local path="$1"
  printf '%s' "$identity_content" >"$TEST_ROOT/expected-identity"
  files_identical "$TEST_ROOT/expected-identity" "$path" ||
    _test_die "identity is not byte-identical to its source: $path"
}

assert_mode_600() {
  local path="$1"
  [[ "$(stat -c '%a' "$path")" == 600 ]] ||
    _test_die "expected mode 0600: $path"
}

library_env() {
  local root="$1"
  printf '%s\n' \
    "HOME=$root/home" \
    "XDG_CONFIG_HOME=$root/config" \
    "XDG_DATA_HOME=$root/data" \
    "XDG_STATE_HOME=$root/state" \
    "DOTFILES_GIT_IDENTITY_BACKUP_DIR=$root/backup" \
    "DOTFILES_GIT_IDENTITY_HISTORY_REPO=$root/history-repo" \
    "DOTFILES_GIT_IDENTITY_HISTORY_RECOVERY=${history_recovery:-false}"
}

# run_library <root> <shell-snippet>: source the library in a clean process
# with the fixture environment and run one snippet against it.
run_library() {
  local root="$1"
  local snippet="$2"
  local -a env_args=()
  mapfile -t env_args < <(library_env "$root")

  # shellcheck disable=SC2016 # The payload expands in the child bash, not here.
  run_capture env "${env_args[@]}" bash -c '
    set -euo pipefail
    source "$1/common/lib/common.sh"
    source "$1/common/lib/git-identity.sh"
    shift
    eval "$1"
  ' bash "$repo_root" "$snippet"
}

# new_history_repo <root> <mode>: a temporary repository whose history is
# built for exactly one scenario.
#
#   valid    a commit adds the legacy identity, a later commit deletes it
#   invalid  the historical blob has no [user] section
#   absent   the path was never tracked
#   shallow  the identity commit exists but is grafted away by a shallow clone
new_history_repo() {
  local root="$1"
  local mode="$2"
  local repo="$root/history-repo"
  local relative="git/.config/git/local"

  rm -rf -- "$repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=main
  git -C "$repo" config user.email "fixture@example.invalid"
  git -C "$repo" config user.name "Fixture"
  git -C "$repo" config commit.gpgsign false

  printf 'seed\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit --quiet -m "seed"

  case "$mode" in
  absent)
    return 0
    ;;
  valid | shallow)
    mkdir -p "$repo/$(dirname "$relative")"
    printf '%s' "$identity_content" >"$repo/$relative"
    ;;
  invalid)
    mkdir -p "$repo/$(dirname "$relative")"
    printf '# a comment, and no user section at all\n' >"$repo/$relative"
    ;;
  *)
    printf 'unknown history mode: %s\n' "$mode" >&2
    return 1
    ;;
  esac

  git -C "$repo" add "$relative"
  git -C "$repo" commit --quiet -m "add legacy identity"
  git -C "$repo" rm --quiet "$relative"
  git -C "$repo" commit --quiet -m "stop tracking the legacy identity"

  if [[ "$mode" == shallow ]]; then
    local shallow="$root/history-repo-shallow"
    rm -rf -- "$shallow"
    git clone --quiet --depth 1 "file://$repo" "$shallow"
    rm -rf -- "$repo"
    mv -- "$shallow" "$repo"
  fi
}

new_machine() {
  test_new_root
  machine="$TEST_ROOT"
  mkdir -p "$machine/home" "$machine/config/git" "$machine/backup"
  history_recovery=false
}

# --- Validation contract ---------------------------------------------------

new_machine
printf '%s' "$identity_content" >"$machine/valid"
printf '# only a comment\n' >"$machine/comment-only"
: >"$machine/empty"
printf '[user]\n' >"$machine/header-only"
printf '[usermode]\n\tname = x\n' >"$machine/wrong-section"
printf '[USER]\n\tEMAIL = x@example.invalid\n' >"$machine/upper-case"

for candidate in valid upper-case; do
  run_library "$machine" "git_identity_is_valid '$machine/$candidate'"
  assert_success
done
for candidate in comment-only empty header-only wrong-section missing; do
  run_library "$machine" "git_identity_is_valid '$machine/$candidate'"
  assert_failure
done
printf 'PASS: only a real [user] section counts as a recoverable identity\n'

# --- Explicit backup source ------------------------------------------------

new_machine
new_history_repo "$machine" absent
printf '%s' "$identity_content" >"$machine/backup/local"
chmod 600 "$machine/backup/local"

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=migrated"
assert_contains "$TEST_OUTPUT" "migrated from the backup source"
assert_not_contains "$TEST_OUTPUT" "$identity_email"
assert_not_contains "$TEST_OUTPUT" "$identity_name"
assert_identical "$machine/config/git/local"
assert_mode_600 "$machine/config/git/local"
printf 'PASS: an explicit local backup migrates byte-for-byte at mode 0600\n'

# --- No-op rerun after a successful migration ------------------------------

before="$machine/before"
cp -- "$machine/config/git/local" "$before"
run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=migrated"
files_identical "$before" "$machine/config/git/local" ||
  _test_die "rerunning migration changed an already-migrated identity"
assert_mode_600 "$machine/config/git/local"
printf 'PASS: rerunning migration over a migrated identity is a no-op\n'

# --- Missing source: manual action, never an empty success artifact --------

new_machine
new_history_repo "$machine" absent

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
assert_contains "$TEST_OUTPUT" "manual action required"
placeholder="$machine/config/git/local"
[[ -s "$placeholder" ]] ||
  _test_die "a failed migration left an empty file behind"
assert_mode_600 "$placeholder"
run_library "$machine" "git_identity_is_valid '$placeholder'"
assert_failure
printf 'PASS: a failed migration leaves an explicit placeholder, not a valid-looking identity\n'

# --- Invalid content is rejected, not installed ----------------------------

new_machine
new_history_repo "$machine" absent
printf '# no user section here\n' >"$machine/backup/local"

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
assert_contains "$TEST_OUTPUT" "no usable [user] section"
assert_file_not_contains "$machine/config/git/local" "no user section here"
printf 'PASS: invalid backup content is rejected without being installed\n'

# --- History recovery is opt-in -------------------------------------------

new_machine
new_history_repo "$machine" valid

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
printf 'PASS: recoverable history is not used unless recovery is enabled\n'

# --- History recovery, enabled, full history -------------------------------

new_machine
new_history_repo "$machine" valid
history_recovery=true

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=migrated"
assert_contains "$TEST_OUTPUT" "migrated from the history source"
assert_not_contains "$TEST_OUTPUT" "$identity_email"
assert_identical "$machine/config/git/local"
assert_mode_600 "$machine/config/git/local"
printf 'PASS: opt-in history recovery restores a valid identity byte-for-byte\n'

# --- History recovery, enabled, shallow clone ------------------------------

new_machine
new_history_repo "$machine" shallow
history_recovery=true

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
assert_contains "$TEST_OUTPUT" "shallow clone"
run_library "$machine" "git_identity_is_valid '$machine/config/git/local'"
assert_failure
printf 'PASS: a shallow clone reports manual action instead of failing or faking success\n'

# --- History recovery, enabled, historical content is invalid --------------

new_machine
new_history_repo "$machine" invalid
history_recovery=true

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
printf 'PASS: historical content without a [user] section never installs\n'

# --- History recovery, enabled, no repository at all -----------------------

new_machine
history_recovery=true
rm -rf -- "$machine/history-repo"

run_library "$machine" "git_identity_migrate local '$machine/config/git/local'
printf 'OUTCOME=%s\n' \"\$GIT_IDENTITY_OUTCOME\""
assert_success
assert_contains "$TEST_OUTPUT" "OUTCOME=manual-action-required"
printf 'PASS: a checkout with no history reports manual action\n'

# --- setup-local end to end, hermetic --------------------------------------
#
# The legacy layout this migrates from is a symlink into the repository's own
# (now untracked) Stow package. The fixture creates that link and a backup, so
# no scenario depends on the real repository history.

new_machine
mkdir -p "$machine/home/.config/git"
for slot in local drdk; do
  ln -s "$repo_root/git/.config/git/$slot" "$machine/home/.config/git/$slot"
  printf '%s' "$identity_content" >"$machine/backup/$slot"
done

run_capture env \
  "HOME=$machine/home" \
  "XDG_CONFIG_HOME=$machine/home/.config" \
  "XDG_DATA_HOME=$machine/home/.local/share" \
  "XDG_STATE_HOME=$machine/home/.local/state" \
  "DOTFILES_GIT_IDENTITY_BACKUP_DIR=$machine/backup" \
  "$repo_root/common/setup-local.sh" fedora macchiato
assert_success
assert_contains "$TEST_OUTPUT" "2 slot(s) migrated"
assert_not_contains "$TEST_OUTPUT" "$identity_email"
for slot in local drdk; do
  slot_path="$machine/home/.config/git/$slot"
  [[ -f "$slot_path" && ! -L "$slot_path" ]] ||
    _test_die "expected a machine-local file: $slot_path"
  assert_identical "$slot_path"
  assert_mode_600 "$slot_path"
done
printf 'PASS: setup-local migrates legacy identity links from an explicit backup\n'

# --- the same migration, through a symlinked checkout ----------------------
#
# DOTFILES_ROOT is logical: it is built with cd/pwd, so it keeps the symlink the
# entry point was reached through, while the legacy link resolves physically.
# Compared as written the two never match, and setup-local would keep the legacy
# link and then write machine-local Git identities through it, back into the
# worktree.

new_machine
linked_repo="$machine/linked-repo"
ln -s "$repo_root" "$linked_repo"
mkdir -p "$machine/home/.config/git"
for slot in local drdk; do
  ln -s "$repo_root/git/.config/git/$slot" "$machine/home/.config/git/$slot"
  printf '%s' "$identity_content" >"$machine/backup/$slot"
done

run_capture env \
  "HOME=$machine/home" \
  "XDG_CONFIG_HOME=$machine/home/.config" \
  "XDG_DATA_HOME=$machine/home/.local/share" \
  "XDG_STATE_HOME=$machine/home/.local/state" \
  "DOTFILES_GIT_IDENTITY_BACKUP_DIR=$machine/backup" \
  "$linked_repo/common/setup-local.sh" fedora macchiato
assert_success
assert_contains "$TEST_OUTPUT" "2 slot(s) migrated"
for slot in local drdk; do
  slot_path="$machine/home/.config/git/$slot"
  [[ -f "$slot_path" && ! -L "$slot_path" ]] ||
    _test_die "a legacy identity link survived a checkout reached through a symlink, so identities would be written into the worktree: $slot_path"
  assert_identical "$slot_path"
  assert_mode_600 "$slot_path"
done
printf 'PASS: setup-local recognizes legacy identity links from a symlinked checkout\n'

# --- setup-local with no migration source ----------------------------------

new_machine
mkdir -p "$machine/home/.config/git"
for slot in local drdk; do
  ln -s "$repo_root/git/.config/git/$slot" "$machine/home/.config/git/$slot"
done

run_capture env \
  "HOME=$machine/home" \
  "XDG_CONFIG_HOME=$machine/home/.config" \
  "XDG_DATA_HOME=$machine/home/.local/share" \
  "XDG_STATE_HOME=$machine/home/.local/state" \
  "DOTFILES_GIT_IDENTITY_BACKUP_DIR=$machine/backup" \
  "$repo_root/common/setup-local.sh" fedora macchiato
assert_success
assert_contains "$TEST_OUTPUT" "need manual action"
for slot in local drdk; do
  slot_path="$machine/home/.config/git/$slot"
  [[ -f "$slot_path" && ! -L "$slot_path" ]] ||
    _test_die "expected a machine-local file: $slot_path"
  run_library "$machine" "git_identity_is_valid '$slot_path'"
  assert_failure
done
printf 'PASS: setup-local reports manual action rather than inventing an identity\n'

printf '\nAll Git identity migration checks passed.\n'
