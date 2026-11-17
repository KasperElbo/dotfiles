#!/usr/bin/env bash
# ./update (#561): when it refuses, when it does nothing, and what it lists and
# runs when there is something to apply.
#
# A throwaway bare origin stands in for GitHub and a forge clone lands pull
# requests on it the ways main has: as `Merge pull request #N` merges, as squash
# commits titled `Title (#N)`, and as commits pushed straight to main. The
# machine clone under test carries this checkout's ./update and the libraries it
# loads, and its install.sh is a one-line shim into the strict stub, which
# accepts exactly `--rerun` and `--rerun --dry-run`. Git itself is real, so the
# refusals, the fast-forward and the listing are all exercised for real.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git
test_new_root
root="$TEST_ROOT"

export HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$root/gitconfig"
git config --global user.name "Fixture"
git config --global user.email "fixture@example.invalid"
git config --global commit.gpgsign false
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/profile-state.sh
source "$repo_root/common/lib/profile-state.sh"

test_stub_install "$root" install.sh
test_stub_allow "$root" install.sh --rerun
test_stub_allow "$root" install.sh --rerun --dry-run

origin="$root/origin.git"
forge="$root/forge"
machine="$root/machine"
state="$XDG_STATE_HOME/dotfiles/install.conf"

# --- Fixtures --------------------------------------------------------------

git init --quiet --bare "$origin"
git clone --quiet "$origin" "$forge" 2>/dev/null
while IFS= read -r file; do
  mkdir -p "$forge/$(dirname -- "$file")"
  cp -p -- "$repo_root/$file" "$forge/$file"
done < <(printf '%s\n' update scripts/update.sh; git -C "$repo_root" ls-files -- common/lib config)
printf '#!/usr/bin/env bash\nexec "$TEST_STUB_ROOT/bin/install.sh" "$@"\n' >"$forge/install.sh"
chmod 755 "$forge/install.sh"
git -C "$forge" add --all
git -C "$forge" commit --quiet -m "Seed the checkout"
git -C "$forge" push --quiet -u origin main
git clone --quiet "$origin" "$machine"

head_of() {
  git -C "$1" rev-parse HEAD
}

short_of() {
  git -C "$machine" rev-parse --short "$1"
}

# record_install <revision> <status>: the lifecycle record an installation of
# <revision> leaves, with a remembered configuration for --rerun to reapply.
record_install() {
  profile_state_write "$state" install "$2" platform=fedora \
    requested_capabilities=base observed_capabilities=base \
    external_assurance=not-recorded repository=fixture \
    "revision=$1" "provenance=capability-manifest@$1" \
    started_at=2026-11-01T00:00:00Z finished_at=2026-11-01T00:10:00Z \
    rerun=./install.sh last_successful_selection=theme:mocha \
    last_successful_platform=fedora last_successful_at=2026-11-01T00:10:00Z \
    selection_schema=1
}

# land_merge <number> <title>: the forge merges a branch the way GitHub's merge
# button does, with the title as the first line of the body.
land_merge() {
  local number="$1" title="$2"
  git -C "$forge" switch --quiet -c "pr-$number" main
  printf '%s\n' "$title" >"$forge/pr-$number.txt"
  git -C "$forge" add -- "pr-$number.txt"
  git -C "$forge" commit --quiet -m "Branch work for #$number"
  git -C "$forge" switch --quiet main
  git -C "$forge" merge --quiet --no-ff "pr-$number" \
    -m "Merge pull request #$number from fixture/pr-$number" -m "$title"
  git -C "$forge" push --quiet origin main
}

# land_squash <number> <title> [file]: the forge squash-merges a pull request
# that changes [file], a new file by default.
land_squash() {
  local number="$1" title="$2" file="${3:-pr-$1.txt}"
  printf '# %s\n' "$title" >>"$forge/$file"
  git -C "$forge" add -- "$file"
  git -C "$forge" commit --quiet -m "$title (#$number)"
  git -C "$forge" push --quiet origin main
}

land_direct() {
  printf '%s\n' "$1" >>"$forge/direct.txt"
  git -C "$forge" add -- direct.txt
  git -C "$forge" commit --quiet -m "$1"
  git -C "$forge" push --quiet origin main
}

run_update() {
  : >"$root/logs/install.sh.log"
  run_capture "$machine/update" "$@"
}

assert_installer_not_run() {
  assert_eq "" "$(test_stub_log "$root" install.sh)" 'installer invocations'
}

assert_installer_ran() {
  assert_eq "$*" "$(test_stub_log "$root" install.sh)" 'installer invocations'
}

# --- Nothing to reapply ----------------------------------------------------

land_direct "Ahead of the machine"
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" 'No installation has been recorded on this machine'
assert_contains "$TEST_OUTPUT" 'Nothing was pulled or installed.'
assert_eq "$(git -C "$machine" rev-parse origin/main)" "$(head_of "$machine")" 'machine HEAD after a refusal'
assert_installer_not_run
printf 'PASS: a machine with nothing to reapply is refused before the pull\n'

git -C "$machine" pull --quiet --ff-only
record_install "$(head_of "$machine")" installed

# --- Already up to date ----------------------------------------------------

run_update
assert_success
assert_eq "Already up to date: main is at $(short_of HEAD) and that revision is installed." \
  "$TEST_OUTPUT" 'up-to-date output'
assert_installer_not_run
printf 'PASS: an installed, current checkout is left alone and says so\n'

# --- Wrong branch ----------------------------------------------------------

land_direct "Behind the topic branch"
installed="$(head_of "$machine")"
git -C "$machine" switch --quiet -c topic
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" './update only updates main, and this checkout is on topic.'
assert_contains "$TEST_OUTPUT" 'Switch with: git switch main'
assert_eq "$installed" "$(head_of "$machine")" 'topic HEAD after a refusal'
assert_installer_not_run
printf 'PASS: a checkout on another branch is refused\n'

git -C "$machine" switch --quiet --detach main
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" './update only updates main, and this checkout is on a detached HEAD.'
assert_installer_not_run
printf 'PASS: a detached HEAD is refused\n'

git -C "$machine" switch --quiet main
git -C "$machine" branch --quiet -D topic

# --- Dirty tree ------------------------------------------------------------

printf 'local edit\n' >>"$machine/direct.txt"
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" './update refuses to pull over uncommitted changes:'
assert_contains "$TEST_OUTPUT" ' M '
assert_eq "$installed" "$(head_of "$machine")" 'machine HEAD after a refusal'
assert_installer_not_run
git -C "$machine" checkout --quiet -- .
printf 'PASS: a tracked change is refused\n'

printf 'notes\n' >"$machine/notes.txt"
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" '?? notes.txt'
assert_eq "$installed" "$(head_of "$machine")" 'machine HEAD after a refusal'
assert_installer_not_run
rm -f -- "$machine/notes.txt"
printf 'PASS: an untracked file is refused\n'

# --- The normal path -------------------------------------------------------

# #102 rewrites ./update's own implementation, shifting every line, so the run
# that pulls it is reading a file the pull replaced.
land_merge 101 "Add the first thing"
land_squash 102 "Rewrite part of the updater" scripts/update.sh
land_direct "A commit straight to main"
run_update
assert_success
expected="Pulled main $(short_of "$installed")..$(short_of origin/main).
Merged since the installed revision $(short_of "$installed"):
  $(short_of origin/main~3) Behind the topic branch (no pull request)
  #101 Add the first thing
  #102 Rewrite part of the updater
  $(short_of origin/main) A commit straight to main (no pull request)

Running ./install.sh --rerun"
assert_eq "$expected" "$TEST_OUTPUT" 'normal-path output'
assert_eq "$(git -C "$machine" rev-parse origin/main)" "$(head_of "$machine")" 'machine HEAD after the pull'
assert_not_contains "$TEST_OUTPUT" 'Branch work'
assert_installer_ran --rerun
printf 'PASS: the pull is listed one pull request a line and the installer reruns\n'

# --- --dry-run, then the real run ------------------------------------------

record_install "$(head_of "$machine")" installed
installed="$(head_of "$machine")"
land_squash 103 "Add the third thing"
run_update --dry-run
assert_success
assert_contains "$TEST_OUTPUT" "Merged since the installed revision $(short_of "$installed"):
  #103 Add the third thing"
assert_eq "$(git -C "$machine" rev-parse origin/main)" "$(head_of "$machine")" 'machine HEAD after a dry run'
assert_installer_ran --rerun --dry-run
printf 'PASS: --dry-run pulls and previews with the incoming installer\n'

# A dry run installs nothing, so the record still names the old revision and the
# next run applies what the dry run only previewed, though it pulls nothing.
run_update
assert_success
assert_contains "$TEST_OUTPUT" "main is already at $(short_of HEAD); the pull brought nothing new."
assert_contains "$TEST_OUTPUT" '  #103 Add the third thing'
assert_installer_ran --rerun
printf 'PASS: a run after a dry run applies what the dry run previewed\n'

# --- A failed installation -------------------------------------------------

record_install "$(head_of "$machine")" failed
run_update
assert_success
assert_contains "$TEST_OUTPUT" "The last installation, of $(short_of HEAD), is \"failed\"."
assert_not_contains "$TEST_OUTPUT" 'Merged since'
assert_installer_ran --rerun
printf 'PASS: a failed installation of the current revision is reapplied\n'

# --- An installed revision main does not have ------------------------------

record_install 0123456789abcdef0123456789abcdef01234567 installed
run_update
assert_success
assert_contains "$TEST_OUTPUT" "The installed revision 0123456789abcdef0123456789abcdef01234567 is not in main's history"
assert_installer_ran --rerun
printf 'PASS: an installed revision outside main is reported, not listed\n'

# --- Diverged main ---------------------------------------------------------

record_install "$(head_of "$machine")" installed
installed="$(head_of "$machine")"
printf 'local commit\n' >"$machine/local.txt"
git -C "$machine" add -- local.txt
git -C "$machine" commit --quiet -m "A commit only this machine has"
land_squash 104 "Add the fourth thing"
run_update
assert_status 1
assert_contains "$TEST_OUTPUT" "Local main has commits its upstream does not, and ./update only fast-forwards."
assert_contains "$TEST_OUTPUT" 'Nothing was installed.'
assert_eq "$installed" "$(git -C "$machine" rev-parse HEAD~1)" 'machine history after a refused pull'
assert_installer_not_run
printf 'PASS: a diverged main is not merged and nothing is installed\n'

# --- Arguments -------------------------------------------------------------

run_update --rerun
assert_status 2
assert_contains "$TEST_OUTPUT" 'Unknown option for ./update: --rerun'
assert_installer_not_run
run_update --help
assert_success
assert_contains "$TEST_OUTPUT" 'Usage: ./update [--dry-run]'
printf 'PASS: only --dry-run and --help are accepted\n'
