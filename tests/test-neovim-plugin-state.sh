#!/usr/bin/env bash
set -uo pipefail

# check_lazy_plugin_state is the verifier's own answer about the Neovim plugin
# tree. It exists because starting Neovim cannot be that answer: the deployed
# configuration installs whatever the profile names and does not find, so a
# start that reaches the end proves only that anything missing has since been
# fetched (issue #371).
#
# This suite needs no Neovim and no network. Every case builds real Git
# checkouts and a real lock file, and the whole run happens under a git that
# refuses to talk to a remote -- so an implementation that tried to fetch
# anything would fail here rather than pass quietly on a connected machine.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/verify.sh
source "$repo_root/common/lib/verify.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

export GIT_CONFIG_GLOBAL="$root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

# Nothing in this check may reach a remote. A git that refuses every remote
# verb is installed for the whole suite, so "offline" is enforced rather than
# asserted in a comment.
offline_bin="$root/offline-bin"
mkdir -p "$offline_bin"
cat >"$offline_bin/git" <<EOF_GIT
#!/usr/bin/env bash
for argument in "\$@"; do
  case "\$argument" in
  clone | fetch | pull | ls-remote | remote)
    printf 'test: check_lazy_plugin_state must not reach the network (%s)\n' \\
      "\$argument" >&2
    exit 99
    ;;
  esac
done
exec $(type -P git) "\$@"
EOF_GIT
chmod +x "$offline_bin/git"
export PATH="$offline_bin:$PATH"

# A plugin checkout with two commits, so a "wrong commit" case has somewhere
# real to point.
make_plugin() {
  local name="$1"
  local dir="$root/plugins/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name Test
  printf 'one\n' >"$dir/file"
  git -C "$dir" add file
  git -C "$dir" commit -qm one
  printf 'two\n' >"$dir/file"
  git -C "$dir" add file
  git -C "$dir" commit -qm two
  git -C "$dir" rev-parse HEAD
}

# Each case gets its own XDG_DATA_HOME and its own lock file, built from the
# plugin checkouts above.
new_tree() {
  local case_name="$1"
  shift
  local data="$root/case-$case_name/data"
  local lazy="$data/nvim/lazy"
  mkdir -p "$lazy"
  local spec name commit
  local json="{"
  local first=1
  for spec in "$@"; do
    name="${spec%%:*}"
    commit="${spec#*:}"
    cp -a "$root/plugins/$name" "$lazy/$name"
    git -C "$lazy/$name" checkout -q "$commit"
    ((first)) || json="$json,"
    first=0
    json="$json\"$name\": {\"branch\": \"main\", \"commit\": \"$commit\"}"
  done
  json="$json}"
  printf '%s\n' "$json" >"$root/case-$case_name/lazy-lock.json"
  export XDG_DATA_HOME="$data"
}

lazy_head="$(make_plugin lazy.nvim)"
lazy_old="$(git -C "$root/plugins/lazy.nvim" rev-parse HEAD~1)"
snacks_head="$(make_plugin snacks.nvim)"

printf 'A tree at the locked commits passes\n'
new_tree healthy "lazy.nvim:$lazy_head" "snacks.nvim:$snacks_head"
verify_reset
check_lazy_plugin_state "$root/case-healthy/lazy-lock.json" >/dev/null 2>&1
assert_eq 1 "$VERIFY_PASSES" 'a matching tree passes'
assert_eq 0 "$VERIFY_FAILURES" 'a matching tree records no failure'
assert_eq 0 "$VERIFY_WARNINGS" 'a matching tree records no warning'

printf 'A plugin at the wrong commit fails and names both commits\n'
new_tree drifted "lazy.nvim:$lazy_head" "snacks.nvim:$snacks_head"
git -C "$XDG_DATA_HOME/nvim/lazy/lazy.nvim" checkout -q "$lazy_old"
verify_reset
run_capture check_lazy_plugin_state "$root/case-drifted/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy plugin commit mismatch: lazy.nvim'
assert_contains "$TEST_OUTPUT" "expected $lazy_head"
assert_contains "$TEST_OUTPUT" "found $lazy_old"

printf 'A missing plugin fails and names it\n'
new_tree absent "lazy.nvim:$lazy_head" "snacks.nvim:$snacks_head"
rm -rf "$XDG_DATA_HOME/nvim/lazy/snacks.nvim"
verify_reset
run_capture check_lazy_plugin_state "$root/case-absent/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy plugin not installed: snacks.nvim'

# The bootstrap case. lazy.nvim is an ordinary lock-file entry, so its absence
# has to be reported by name like any other plugin rather than falling through
# as a missing root.
printf 'A missing lazy.nvim is reported by name\n'
new_tree nobootstrap "lazy.nvim:$lazy_head" "snacks.nvim:$snacks_head"
rm -rf "$XDG_DATA_HOME/nvim/lazy/lazy.nvim"
verify_reset
run_capture check_lazy_plugin_state "$root/case-nobootstrap/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy plugin not installed: lazy.nvim'

# An interrupted clone leaves a directory behind. A check that asked only
# whether the directory existed would credit it, which is the same defect
# Mason receipts exist to close.
printf 'A directory that is not a checkout fails\n'
new_tree notarepo "lazy.nvim:$lazy_head" "snacks.nvim:$snacks_head"
rm -rf "$XDG_DATA_HOME/nvim/lazy/snacks.nvim/.git"
verify_reset
run_capture check_lazy_plugin_state "$root/case-notarepo/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy plugin is not a Git checkout: snacks.nvim'

printf 'A plugin the lock file does not name warns without failing\n'
new_tree extra "lazy.nvim:$lazy_head"
cp -a "$root/plugins/snacks.nvim" "$XDG_DATA_HOME/nvim/lazy/snacks.nvim"
verify_reset
check_lazy_plugin_state "$root/case-extra/lazy-lock.json" >/dev/null 2>&1
assert_eq 0 "$VERIFY_FAILURES" 'an unlisted plugin is not a failure'
assert_eq 1 "$VERIFY_WARNINGS" 'an unlisted plugin warns'
assert_eq 1 "$VERIFY_PASSES" 'the locked plugins still pass'

printf 'A missing lock file fails\n'
new_tree nolock "lazy.nvim:$lazy_head"
verify_reset
run_capture check_lazy_plugin_state "$root/case-nolock/absent-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy lock file missing'

# A lock file this checkout cannot parse must not arrive as "no plugins
# locked": an unreadable record is a failure about the record, and saying so
# is what stops a corrupt file reading as an empty one.
printf 'A corrupt lock file is told apart from an empty one\n'
new_tree corrupt "lazy.nvim:$lazy_head"
printf '{ not json\n' >"$root/case-corrupt/lazy-lock.json"
verify_reset
run_capture check_lazy_plugin_state "$root/case-corrupt/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'not valid JSON'
assert_not_contains "$TEST_OUTPUT" 'names no plugins'

printf 'An empty lock file fails as an empty one\n'
new_tree emptylock "lazy.nvim:$lazy_head"
printf '{}\n' >"$root/case-emptylock/lazy-lock.json"
verify_reset
run_capture check_lazy_plugin_state "$root/case-emptylock/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'names no plugins'

printf 'A lock entry with no commit fails rather than matching anything\n'
new_tree nocommit "lazy.nvim:$lazy_head"
printf '{"lazy.nvim": {"branch": "main"}}\n' >"$root/case-nocommit/lazy-lock.json"
verify_reset
run_capture check_lazy_plugin_state "$root/case-nocommit/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'records no commit for lazy.nvim'

printf 'A missing plugin root fails\n'
new_tree noroot "lazy.nvim:$lazy_head"
rm -rf "$XDG_DATA_HOME/nvim/lazy"
verify_reset
run_capture check_lazy_plugin_state "$root/case-noroot/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'Lazy plugin root missing'

# The prerequisite must fail loudly. A check that credited a machine because
# its JSON parser was missing would report a clean plugin tree it never read.
printf 'A missing jq fails loudly instead of skipping\n'
new_tree nojq "lazy.nvim:$lazy_head"
# A PATH holding the ordinary userland and git, but no jq. Built here rather
# than with test_isolate_path because that replaces PATH for the rest of the
# suite, and only this one case is meant to lose jq.
nojq_bin="$root/nojq-bin"
mkdir -p "$nojq_bin"
for host_command in "${TEST_HOST_COMMANDS[@]}"; do
  resolved="$(type -P -- "$host_command" 2>/dev/null)" || continue
  ln -sf -- "$resolved" "$nojq_bin/$host_command"
done
ln -sf -- "$offline_bin/git" "$nojq_bin/git"
verify_reset
run_capture env PATH="$nojq_bin" "$BASH" -c \
  'source common/lib/verify.sh
   XDG_DATA_HOME="$1" check_lazy_plugin_state "$2"' _ \
  "$XDG_DATA_HOME" "$root/case-nojq/lazy-lock.json"
assert_failure
assert_contains "$TEST_OUTPUT" 'jq is required'

# The control: the same isolated PATH with jq linked in must pass, so the case
# above is about jq's absence and not about the isolated PATH itself.
printf 'The same isolated PATH with jq present passes\n'
ln -sf -- "$(type -P jq)" "$nojq_bin/jq"
verify_reset
run_capture env PATH="$nojq_bin" "$BASH" -c \
  'source common/lib/verify.sh
   XDG_DATA_HOME="$1" check_lazy_plugin_state "$2"' _ \
  "$XDG_DATA_HOME" "$root/case-nojq/lazy-lock.json"
assert_success

printf 'Neovim plugin state checks passed.\n'
