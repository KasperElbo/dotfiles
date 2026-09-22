#!/usr/bin/env bash
set -euo pipefail

# AI optional-component transition semantics (additive install, explicit
# removal, provable ownership). Every scenario asserts both the profile state
# and the filesystem, because the contract is that those two can never end a
# successful operation disagreeing.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
mise_data="$data/mise"
mise_shims="$mise_data/shims"
mise_installs="$mise_data/installs"
mkdir -p "$mise_shims" "$mise_installs" "$config" "$data" "$mock_bin"

state_file="$config/dotfiles/ai.conf"
conf_file="$config/mise/conf.d/ai.toml"
treehouse_target="$home/.local/bin/treehouse"
no_mistakes_target="$home/.local/bin/no-mistakes"
firstmate_dir="$data/firstmate"
uninstall_log="$test_root/mise-uninstall.log"

# --- Fixtures ---------------------------------------------------------------

cat >"$mock_bin/mise" <<'EOF'
#!/usr/bin/env bash
set -u
conf_file="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"

reject() {
  printf 'strict mise fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
}

# mise must always be invoked from the deterministic context, never from the
# caller's directory. A fixture that accepted any working directory would let
# the isolation regress silently.
[[ "$PWD" == "$MISE_EXPECTED_CONTEXT" ]] || {
  printf 'mise fixture: unexpected working directory %s (want %s)\n' \
    "$PWD" "$MISE_EXPECTED_CONTEXT" >&2
  exit 94
}

make_shim() {
  local install_bin="$MISE_INSTALLS_DIR/$1/latest/bin/$1"
  mkdir -p "$(dirname "$install_bin")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$install_bin"
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$MISE_SHIMS_DIR/$1"
  chmod +x "$MISE_SHIMS_DIR/$1"
}

declaration_for() {
  case "$1" in
  claude) printf '"npm:@anthropic-ai/claude-code"' ;;
  herdr) printf 'herdr' ;;
  codex) printf '"npm:@openai/codex"' ;;
  *) printf '"npm:%s"' "$1" ;;
  esac
}

case "${1:-}" in
--yes)
  [[ "${2:-}" == install ]] || reject "$@"
  mkdir -p "$MISE_SHIMS_DIR"
  for tool in claude herdr codex gnhf gh-axi chrome-devtools-axi lavish-axi \
    tasks-axi quota-axi backpass acpx; do
    if grep -Fq "$(declaration_for "$tool")" "$conf_file" 2>/dev/null; then
      make_shim "$tool"
    fi
  done
  exit 0
  ;;
exec)
  [[ "${2:-}" == -- ]] || reject "$@"
  shift 2
  PATH="$MISE_SHIMS_DIR:$PATH" exec "$@"
  ;;
uninstall)
  [[ $# -eq 2 ]] || reject "$@"
  printf '%s\n' "$2" >>"${MISE_UNINSTALL_LOG:-/dev/null}"
  # A real mise uninstall can fail -- the package is busy, its directory is
  # not writable, the backend errors. The tool stays installed when it does.
  if [[ -n "${MOCK_MISE_UNINSTALL_FAIL:-}" && "$2" == "$MOCK_MISE_UNINSTALL_FAIL" ]]; then
    printf 'mise fixture: refusing to uninstall %s\n' "$2" >&2
    exit 1
  fi
  case "$2" in
  npm:@openai/codex) rm -rf -- "$MISE_INSTALLS_DIR/codex" "$MISE_SHIMS_DIR/codex" ;;
  npm:*)
    name="${2#npm:}"
    rm -rf -- "$MISE_INSTALLS_DIR/$name" "$MISE_SHIMS_DIR/$name"
    ;;
  *) rm -rf -- "$MISE_INSTALLS_DIR/$2" "$MISE_SHIMS_DIR/$2" ;;
  esac
  exit 0
  ;;
which)
  [[ $# -eq 2 ]] || reject "$@"
  install_bin="$MISE_INSTALLS_DIR/$2/latest/bin/$2"
  [[ -x "$install_bin" ]] || exit 1
  printf '%s\n' "$install_bin"
  ;;
*) reject "$@" ;;
esac
EOF
chmod +x "$mock_bin/mise"

test_stub_npm_global "$mock_bin"

cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output=""
url=""
while (($#)); do
  case "$1" in
  --output)
    output="${2:-}"
    shift 2
    ;;
  --) url="${2:-}"; shift "$#" ;;
  *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 96
case "$url" in
*treehouse*) name=treehouse ;;
*no-mistakes*) name=no-mistakes ;;
*) exit 96 ;;
esac
# No Mistakes on darwin/arm64 installs into its own directory and leaves a
# launcher symlink on PATH. Removal has to delete the binary behind the link,
# so the fixture can produce either layout.
if [[ "$name" == no-mistakes && "${MOCK_NO_MISTAKES_LAYOUT:-direct}" == launcher ]]; then
  {
    printf '#!/usr/bin/env sh\n'
    printf 'mkdir -p "$HOME/.no-mistakes/bin" "$HOME/.local/bin"\n'
    printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.no-mistakes/bin/no-mistakes"\n'
    printf 'chmod +x "$HOME/.no-mistakes/bin/no-mistakes"\n'
    printf 'ln -sf "$HOME/.no-mistakes/bin/no-mistakes" "$HOME/.local/bin/no-mistakes"\n'
  } >"$output"
  exit 0
fi
{
  printf '#!/usr/bin/env sh\n'
  printf 'mkdir -p "$HOME/.local/bin"\n'
  printf 'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$HOME/.local/bin/%s"\n' "$name"
  printf 'chmod +x "$HOME/.local/bin/%s"\n' "$name"
} >"$output"
EOF
chmod +x "$mock_bin/curl"

cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
# The verifier asks both logins for their PATH through a marker. Only the
# interactive login carries mise's shims, because mise is activated in .zshrc
# while .zshenv is read by both.
case "${1:-}" in
-lc) printf 'login-path:%s\n' "$HOME/.local/bin:/usr/bin:/bin" ;;
*) printf 'login-path:%s\n' "$HOME/.local/bin:$MISE_SHIMS_DIR:$PATH" ;;
esac
EOF
chmod +x "$mock_bin/zsh"

for command_name in gh tmux; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$mock_bin/$command_name"
  chmod +x "$mock_bin/$command_name"
done

# jq is the real one: the installer reads and rewrites Claude Code's settings
# file with it, and a stub that exits 0 without output would let every JSON
# assertion pass while writing nothing.
ln -sf "$(command -v jq)" "$mock_bin/jq"

firstmate_origin="$test_root/firstmate-origin"
mkdir -p "$firstmate_origin"
git -C "$firstmate_origin" init -q
git -C "$firstmate_origin" config user.name Test
git -C "$firstmate_origin" config user.email test@example.invalid
printf '# FirstMate fixture\n' >"$firstmate_origin/README.md"
git -C "$firstmate_origin" add README.md
git -C "$firstmate_origin" commit -qm 'Initial commit'

mise_context="$test_root/state/dotfiles/mise-context"

install_ai() {
  env \
    HOME="$home" CODEX_HOME="$home/.codex" \
    XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
    XDG_STATE_HOME="$test_root/state" \
    PATH="$mock_bin:$PATH" \
    MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
    MISE_INSTALLS_DIR="$mise_installs" \
    MISE_UNINSTALL_LOG="$uninstall_log" \
    MISE_EXPECTED_CONTEXT="$mise_context" \
    FIRSTMATE_REPO_URL="$firstmate_origin" \
    MOCK_NO_MISTAKES_LAYOUT="${MOCK_NO_MISTAKES_LAYOUT:-direct}" \
    MOCK_MISE_UNINSTALL_FAIL="${MOCK_MISE_UNINSTALL_FAIL:-}" \
    "$repo_root/common/install-ai.sh" "$@"
}

verify_ai() {
  env \
    HOME="$home" CODEX_HOME="$home/.codex" \
    XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
    XDG_STATE_HOME="$test_root/state" \
    PATH="$home/.local/bin:$mise_shims:$mock_bin:$PATH" \
    MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
    MISE_INSTALLS_DIR="$mise_installs" \
    MISE_EXPECTED_CONTEXT="$mise_context" \
    "$repo_root/common/verify-ai.sh"
}

state_says() {
  assert_file_line "$state_file" "$1"
}

# --- 1. Fresh core-only install --------------------------------------------

install_ai >"$test_root/core.log" 2>&1 ||
  { cat "$test_root/core.log" >&2; exit 1; }
state_says 'requested=none'
state_says 'codex=disabled'
state_says 'firstmate=disabled'
assert_path_missing "$firstmate_dir"
assert_path_missing "$treehouse_target"
verify_ai >/dev/null
printf 'PASS: fresh core-only install\n'

# --- 2. Add one component ---------------------------------------------------

install_ai --codex >"$test_root/add-codex.log" 2>&1 ||
  { cat "$test_root/add-codex.log" >&2; exit 1; }
state_says 'requested=codex'
state_says 'codex=mise-npm'
assert_file_contains "$conf_file" '"npm:@openai/codex"'
assert_file_empty "$uninstall_log"
printf 'PASS: adding one component installs only that component\n'

# --- 3. No-op rerun ---------------------------------------------------------

before="$(sha256sum "$state_file" "$conf_file")"
install_ai --codex >/dev/null 2>&1
assert_eq "$before" "$(sha256sum "$state_file" "$conf_file")" 'no-op rerun changed state'
printf 'PASS: a no-op rerun changes nothing\n'

# --- 4. Full install --------------------------------------------------------

install_ai --codex --firstmate --gnhf --backpass >"$test_root/full.log" 2>&1 ||
  { cat "$test_root/full.log" >&2; exit 1; }
state_says 'requested=codex,firstmate,gnhf,backpass'
state_says 'firstmate=cloned'
state_says 'treehouse=installed'
state_says 'no_mistakes=installed'
assert_path_exists "$firstmate_dir/.git"
assert_path_executable "$treehouse_target"
assert_path_executable "$no_mistakes_target"
assert_file_empty "$uninstall_log"
verify_ai >/dev/null
printf 'PASS: full install\n'

# --- 5. Omitting an installed component preserves it ------------------------
#
# This is the defect issue #146 names: the old installer rewrote state to
# "disabled" while leaving every artifact on disk.

install_ai >"$test_root/omit.log" 2>&1 ||
  { cat "$test_root/omit.log" >&2; exit 1; }
state_says 'requested=codex,firstmate,gnhf,backpass'
state_says 'codex=mise-npm'
state_says 'firstmate=cloned'
state_says 'gnhf=mise-npm'
state_says 'backpass=mise-npm'
assert_path_exists "$firstmate_dir/.git"
assert_path_executable "$treehouse_target"
assert_file_contains "$conf_file" '"npm:@openai/codex"'
assert_file_empty "$uninstall_log"
verify_ai >/dev/null
printf 'PASS: omitting a sub-flag preserves the installed component\n'

# --- 6. Dry-run previews a removal and changes nothing ----------------------

dry_run_output="$(install_ai --no-codex --dry-run)"
assert_contains "$dry_run_output" 'codex        remove'
assert_contains "$dry_run_output" 'firstmate    keep'
assert_contains "$dry_run_output" 'mise uninstall npm:@openai/codex'
state_says 'codex=mise-npm'
assert_file_empty "$uninstall_log"
printf 'PASS: dry-run previews the removal without performing it\n'

# --- 7. A removal without acknowledgement is declined -----------------------

if printf 'n\n' | install_ai --no-codex >"$test_root/declined.log" 2>&1; then
  printf 'install-ai.sh removed a component without confirmation\n' >&2
  exit 1
fi
assert_file_contains "$test_root/declined.log" 'Removal declined'
state_says 'codex=mise-npm'
assert_file_empty "$uninstall_log"
printf 'PASS: an unconfirmed removal changes nothing\n'

# --- 8. Explicit disable with a non-interactive acknowledgement -------------

install_ai --no-codex --non-interactive >"$test_root/remove-codex.log" 2>&1 ||
  { cat "$test_root/remove-codex.log" >&2; exit 1; }
state_says 'codex=disabled'
state_says 'requested=firstmate,gnhf,backpass'
assert_file_not_contains "$conf_file" '"npm:@openai/codex"'
assert_file_contains "$uninstall_log" 'npm:@openai/codex'
assert_path_missing "$mise_shims/codex"
verify_ai >/dev/null
printf 'PASS: explicit disable removes the component and its declaration\n'

# --- 9. Removal refuses a user-modified target ------------------------------

printf '#!/usr/bin/env sh\n# replaced by the user\nexit 0\n' >"$treehouse_target"
chmod +x "$treehouse_target"
if install_ai --no-firstmate --non-interactive >"$test_root/modified.log" 2>&1; then
  printf 'install-ai.sh removed a user-modified target\n' >&2
  exit 1
fi
assert_file_contains "$test_root/modified.log" 'no longer matches the recorded digest'
assert_file_contains "$test_root/modified.log" 'nothing was changed'
assert_path_executable "$treehouse_target"
assert_path_exists "$firstmate_dir/.git"
state_says 'firstmate=cloned'
printf 'PASS: removal refuses an unprovable target and changes nothing\n'

# --- 10. A dry-run reports the same refusal ---------------------------------

refusal_dry_run="$(install_ai --no-firstmate --dry-run)"
assert_contains "$refusal_dry_run" 'REFUSED, manual action required'
printf 'PASS: dry-run reports the refusal an apply run would reach\n'

# --- 10b. The checkout's own backend config is not a user modification -------
#
# The installer writes config/backend inside the FirstMate checkout, so that
# one path must not read as a local modification. Anything else left in the
# working tree still does.

install_ai --firstmate --non-interactive >"$test_root/repair.log" 2>&1 ||
  { cat "$test_root/repair.log" >&2; exit 1; }
assert_file_contains "$firstmate_dir/config/backend" 'herdr'
printf 'a file the user left behind\n' >"$firstmate_dir/user-notes.txt"
if install_ai --no-firstmate --non-interactive \
  >"$test_root/dirty-checkout.log" 2>&1; then
  printf 'install-ai.sh removed a checkout with unexplained local changes\n' >&2
  exit 1
fi
assert_file_contains "$test_root/dirty-checkout.log" 'has local modifications'
assert_path_exists "$firstmate_dir/.git"
rm -f "$firstmate_dir/user-notes.txt"
printf 'PASS: only the installer-written backend config is discounted\n'

# --- 11. Verification reports a disabled-but-present component --------------
#
# Restoring the recorded binary makes the component ownable again, so the
# removal can complete; the state and the filesystem stay in step throughout.

install_ai --no-firstmate --non-interactive >"$test_root/remove-firstmate.log" 2>&1 ||
  { cat "$test_root/remove-firstmate.log" >&2; exit 1; }
state_says 'firstmate=disabled'
state_says 'treehouse=disabled'
state_says 'no_mistakes=disabled'
assert_path_missing "$firstmate_dir"
assert_path_missing "$treehouse_target"
assert_path_missing "$no_mistakes_target"
verify_ai >/dev/null
printf 'PASS: explicit FirstMate removal deletes exactly the owned paths\n'

# --- 12. Verification fails for an enabled-but-missing component ------------

install_ai --codex --non-interactive >/dev/null 2>&1
rm -f -- "$mise_shims/codex" "$mise_installs/codex/latest/bin/codex"
if verify_ai >"$test_root/missing.log" 2>&1; then
  printf 'verify-ai.sh passed with an enabled component missing\n' >&2
  exit 1
fi
printf 'PASS: verification fails for an enabled component that is missing\n'

# --- 13. Disabled-but-present is reported, never silently rewritten ---------

install_ai --codex --non-interactive >"$test_root/reinstall-codex.log" 2>&1 ||
  { cat "$test_root/reinstall-codex.log" >&2; exit 1; }
install_ai --no-gnhf --non-interactive >"$test_root/remove-gnhf.log" 2>&1 ||
  { cat "$test_root/remove-gnhf.log" >&2; exit 1; }
state_says 'gnhf=disabled'

# Something puts a gnhf back on PATH outside this installer. Verification must
# say so and name the flag that removes it, and must not quietly rewrite state
# to pretend the component is managed again.
printf '#!/usr/bin/env sh\nexit 0\n' >"$home/.local/bin/gnhf"
chmod +x "$home/.local/bin/gnhf"
residual_output="$(verify_ai 2>&1)"
assert_contains "$residual_output" 'gnhf is not selected'
assert_contains "$residual_output" '--no-gnhf'
state_says 'gnhf=disabled'
assert_path_executable "$home/.local/bin/gnhf"
rm -f -- "$home/.local/bin/gnhf"
printf 'PASS: a disabled-but-present component is reported, not rewritten\n'

# --- 14. An interrupted transition leaves accurate state --------------------
#
# Treehouse installs, then No Mistakes fails. The run must not end claiming a
# clean install, and the next run must reconcile without losing anything.

interrupted_bin="$test_root/interrupted-bin"
mkdir -p "$interrupted_bin"
# Copy rather than symlink: writing the replacement curl through a symlink
# would clobber the shared fixture and make it exec itself forever.
cp -- "$mock_bin"/* "$interrupted_bin/"
cat >"$interrupted_bin/curl" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  if [[ "\$argument" == *no-mistakes* ]]; then
    printf 'curl: (7) simulated failure\n' >&2
    exit 7
  fi
done
exec "$mock_bin/curl" "\$@"
EOF
chmod +x "$interrupted_bin/curl"

if env \
  HOME="$home" CODEX_HOME="$home/.codex" \
  XDG_CONFIG_HOME="$config" XDG_DATA_HOME="$data" \
  XDG_STATE_HOME="$test_root/state" \
  PATH="$interrupted_bin:$PATH" \
  MISE_DATA_DIR="$mise_data" MISE_SHIMS_DIR="$mise_shims" \
  MISE_INSTALLS_DIR="$mise_installs" \
  MISE_UNINSTALL_LOG="$uninstall_log" \
  MISE_EXPECTED_CONTEXT="$mise_context" \
  FIRSTMATE_REPO_URL="$firstmate_origin" \
  DOTFILES_FETCH_ATTEMPTS=1 DOTFILES_FETCH_RETRY_DELAY=0 \
  "$repo_root/common/install-ai.sh" --firstmate \
  >"$test_root/interrupted.log" 2>&1; then
  printf 'install-ai.sh reported success after a failed component\n' >&2
  exit 1
fi
assert_file_not_contains "$state_file" 'no_mistakes=installed'
printf 'PASS: an interrupted transition never records the failed component as installed\n'

install_ai --firstmate --non-interactive >"$test_root/recover.log" 2>&1 ||
  { cat "$test_root/recover.log" >&2; exit 1; }
state_says 'firstmate=cloned'
state_says 'treehouse=installed'
state_says 'no_mistakes=installed'
assert_path_executable "$no_mistakes_target"
verify_ai >/dev/null
printf 'PASS: the next run reconciles an interrupted transition\n'

# --- 15. Stale state versus the filesystem ----------------------------------
#
# With the state file gone, additive semantics must not treat "unknown" as
# "unwanted": nothing is uninstalled, and the components stay on disk.

: >"$uninstall_log"
rm -f -- "$state_file"
install_ai >"$test_root/stale.log" 2>&1 ||
  { cat "$test_root/stale.log" >&2; exit 1; }
assert_file_empty "$uninstall_log"
assert_path_exists "$firstmate_dir/.git"
assert_path_executable "$treehouse_target"
state_says 'requested=none'
printf 'PASS: lost state never causes an unrequested uninstall\n'

# --- 16. Removal follows an upstream launcher symlink -----------------------
#
# When an upstream installs its binary elsewhere and links it onto PATH,
# deleting the link alone would leave the tool installed while the state file
# says it is gone. Both paths are named in the preview and both are deleted,
# and the directory the upstream created for itself is pruned once empty.

MOCK_NO_MISTAKES_LAYOUT=launcher install_ai --firstmate --non-interactive \
  >"$test_root/launcher-install.log" 2>&1 ||
  { cat "$test_root/launcher-install.log" >&2; exit 1; }
[[ -L "$no_mistakes_target" ]] || {
  printf 'the launcher fixture did not install a symlink at %s\n' "$no_mistakes_target" >&2
  exit 1
}
# Canonical, because resolving the launcher is what the installer records and
# reports; a test root under a symlinked temporary directory (/var/folders on
# macOS) would otherwise compare two spellings of the same file.
no_mistakes_binary="$(cd -P -- "$home/.no-mistakes/bin" && pwd)/no-mistakes"
assert_path_executable "$no_mistakes_binary"
state_says "no_mistakes_target_path=$no_mistakes_binary"
verify_ai >/dev/null

launcher_preview="$(install_ai --no-firstmate --dry-run)"
assert_contains "$launcher_preview" "delete $no_mistakes_target (no-mistakes)"
assert_contains "$launcher_preview" "delete $no_mistakes_binary (no-mistakes binary)"

install_ai --no-firstmate --non-interactive >"$test_root/launcher-remove.log" 2>&1 ||
  { cat "$test_root/launcher-remove.log" >&2; exit 1; }
state_says 'no_mistakes=disabled'
assert_path_missing "$no_mistakes_target"
assert_path_missing "$no_mistakes_binary"
assert_path_missing "$home/.no-mistakes"
verify_ai >/dev/null
printf 'PASS: removal deletes the binary behind a launcher symlink and prunes its directory\n'

# --- 17. Pruning never reaches beyond the binary it removed -----------------
#
# The upstream directory is pruned because it is empty, not because this
# repository claims it. Anything else the upstream keeps there outlives the
# removal.

MOCK_NO_MISTAKES_LAYOUT=launcher install_ai --firstmate --non-interactive \
  >"$test_root/launcher-config-install.log" 2>&1 ||
  { cat "$test_root/launcher-config-install.log" >&2; exit 1; }
printf 'upstream configuration\n' >"$home/.no-mistakes/config.toml"
install_ai --no-firstmate --non-interactive >"$test_root/launcher-config-remove.log" 2>&1 ||
  { cat "$test_root/launcher-config-remove.log" >&2; exit 1; }
assert_path_missing "$no_mistakes_target"
assert_path_missing "$no_mistakes_binary"
assert_path_missing "$home/.no-mistakes/bin"
assert_path_exists "$home/.no-mistakes/config.toml"
printf 'PASS: pruning stops at a directory the upstream still uses\n'
rm -rf -- "$home/.no-mistakes"

# --- 18. A launcher repointed elsewhere is not ownable ----------------------
#
# The digest alone cannot prove ownership of a symlink: an identical copy
# somewhere else would match it. The binary is deleted only when the command
# still resolves to the exact path recorded at install time.

MOCK_NO_MISTAKES_LAYOUT=launcher install_ai --firstmate --non-interactive \
  >"$test_root/launcher-reinstall.log" 2>&1 ||
  { cat "$test_root/launcher-reinstall.log" >&2; exit 1; }
elsewhere="$home/elsewhere/no-mistakes"
mkdir -p "$(dirname "$elsewhere")"
cp -- "$no_mistakes_binary" "$elsewhere"
ln -sf "$elsewhere" "$no_mistakes_target"

if install_ai --no-firstmate --non-interactive >"$test_root/repointed.log" 2>&1; then
  printf 'install-ai.sh removed a launcher pointing outside the recorded install\n' >&2
  exit 1
fi
assert_file_contains "$test_root/repointed.log" "not the recorded $no_mistakes_binary"
assert_file_contains "$test_root/repointed.log" 'nothing was changed'
assert_path_executable "$elsewhere"
assert_path_executable "$no_mistakes_binary"
state_says 'no_mistakes=installed'
printf 'PASS: a launcher repointed outside the recorded install is refused\n'

# Restore the recorded layout so the suite ends with state and filesystem in
# step, and prove the same removal then completes.
ln -sf "$no_mistakes_binary" "$no_mistakes_target"
rm -rf -- "$(dirname "$elsewhere")"
install_ai --no-firstmate --non-interactive >"$test_root/launcher-remove-2.log" 2>&1 ||
  { cat "$test_root/launcher-remove-2.log" >&2; exit 1; }
assert_path_missing "$no_mistakes_target"
assert_path_missing "$no_mistakes_binary"
verify_ai >/dev/null
printf 'PASS: restoring the recorded launcher makes the component ownable again\n'

# --- 19. A failed uninstall is refused, not recorded as a removal -----------
#
# The conf file is the only record of what was previously declared, so a
# rewrite that drops a spec whose uninstall then fails makes the failure
# permanent: nothing is stale on the next run, so the uninstall is never
# retried, while the tool stays on disk and the state file says it is gone.
# Both halves are asserted here, and the recovery at the end is what proves
# the declaration really did survive.

install_ai --codex --non-interactive >"$test_root/uninstall-fail-add.log" 2>&1 ||
  { cat "$test_root/uninstall-fail-add.log" >&2; exit 1; }
state_says 'codex=mise-npm'
assert_path_executable "$mise_shims/codex"

if MOCK_MISE_UNINSTALL_FAIL='npm:@openai/codex' \
  install_ai --no-codex --non-interactive \
  >"$test_root/uninstall-fail.log" 2>&1; then
  printf 'install-ai.sh reported success after mise failed to uninstall\n' >&2
  exit 1
fi
assert_file_contains "$test_root/uninstall-fail.log" 'it is still installed'
assert_file_contains "$test_root/uninstall-fail.log" 'Refusing to record a removal that did not happen'
assert_file_contains "$test_root/uninstall-fail.log" 'this run changed nothing'
# The tool is still there, and the profile still says so.
assert_path_executable "$mise_shims/codex"
state_says 'codex=mise-npm'
# The declaration survived, which is what lets the next run retry.
assert_file_contains "$conf_file" '"npm:@openai/codex"'
printf 'PASS: a failed uninstall is refused rather than recorded\n'

# Recovery: with mise working again, the same command completes.
: >"$uninstall_log"
install_ai --no-codex --non-interactive >"$test_root/uninstall-retry.log" 2>&1 ||
  { cat "$test_root/uninstall-retry.log" >&2; exit 1; }
assert_file_contains "$uninstall_log" 'npm:@openai/codex'
assert_path_missing "$mise_shims/codex"
state_says 'codex=disabled'
assert_file_not_contains "$conf_file" '"npm:@openai/codex"'
printf 'PASS: the refused removal is retried and completes on the next run\n'

printf 'AI optional-component transition tests passed.\n'
