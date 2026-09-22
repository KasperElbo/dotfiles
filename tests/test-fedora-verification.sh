#!/usr/bin/env bash
set -euo pipefail

# The Fedora platform verifier, platforms/fedora/scripts/verify.sh.
#
# Three defects this suite exists to hold closed, all of the same family: a
# check that decides from something other than the machine.
#
#   * The Sway and KDE sections were gated on their own artifacts, so the thing
#     that was supposed to be verified decided whether it would be verified. A
#     machine that recorded --sway and whose stow step never ran was described
#     by no check at all and scored exactly like one that never asked for Sway
#     (issue #394, GAP-09).
#   * The one mise call in any verifier that did not go through run_mise
#     answered for whatever directory the operator happened to be standing in
#     (issue #396, GAP-12).
#   * Every check_symlink call named only the package a link had to resolve
#     inside, so a link redirected at another file in the same package passed
#     (issue #369).
#
# The fixture is a recorded installation plus a closed PATH. Almost nothing
# else the verifier asks about is true of it, so the exit status alone says
# nothing; every case below asserts the lines its own section contributed, and
# where a count matters it is compared against the same fixture's baseline.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

verifier="$repo_root/platforms/fedora/scripts/verify.sh"

test_install_cleanup_trap
# git is not in the shared host list; the verifier reads the checkout's
# revision through it and falls back to "unknown" when it is absent.
test_isolate_path git
test_new_root
root="$TEST_ROOT"

stub_bin="$root/stubs"
mkdir -p "$stub_bin"
mapfile -t base_environment < <(test_env_args "$root")

# --- Fixture machine ---------------------------------------------------------

# record_selection <capabilities>: a machine whose last installation recorded
# exactly these capabilities, written where profile_state_dir reads it.
record_selection() {
  local capabilities="$1"

  mkdir -p "$root/state/dotfiles"
  cat >"$root/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=$capabilities
observed_capabilities=$capabilities
external_assurance=not-recorded
repository=local-checkout
revision=0123456789abcdef
provenance=capability-manifest@0123456789abcdef
EOF
}

new_machine() {
  rm -rf -- "${root:?}/home" "${root:?}/config" "${root:?}/data" \
    "${root:?}/state" "${root:?}/cache"
  mkdir -p "$root/home" "$root/config" "$root/data" "$root/state" "$root/cache"
  record_selection "$1"
}

# run_verifier: the real verifier in the fixture machine. Extra environment
# assignments are passed through, and the stub directory leads PATH so a
# command a case wants present exists and nothing else does.
run_verifier() {
  local summary
  set +e
  env "${base_environment[@]}" "PATH=$stub_bin:$PATH" "$@" \
    "$verifier" >"$root/verify.out" 2>"$root/verify.err"
  verifier_status=$?
  set -e
  verifier_output="$(cat "$root/verify.out" "$root/verify.err")"
  summary="$(grep -hE '[0-9]+ failure\(s\), [0-9]+ warning\(s\)' \
    "$root/verify.out" "$root/verify.err" | tail -n 1 || true)"
  [[ -n "$summary" ]] ||
    _test_die "the Fedora verifier printed no result summary (status $verifier_status)"
  verifier_failures="$(sed -E 's/.*[^0-9]([0-9]+) failure\(s\).*/\1/' <<<"$summary")"
}

stub_command() {
  local name="$1"
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
  } >"$stub_bin/$name"
  chmod +x "$stub_bin/$name"
}

# ---------------------------------------------------------------------------
# GAP-09: an optional session is described by the selection, not by its own
# leftovers
# ---------------------------------------------------------------------------

sway_section='Sway session'
kde_section='KDE Dolphin/KIO SFTP integration'

new_machine base,dotnet-debug
run_verifier
assert_not_contains "$verifier_output" "$sway_section"
assert_contains "$verifier_output" 'KDE integration is not selected'
assert_not_contains "$verifier_output" "$kde_section"
unselected_failures="$verifier_failures"
printf 'PASS: a machine that selected neither Sway nor KDE is asked about neither\n'

# Selected and never installed. This is the case that used to vanish: no sway
# config on disk, so the artifact gate skipped every check that would have
# named what is missing.
new_machine base,dotnet-debug,sway
run_verifier
assert_contains "$verifier_output" "$sway_section"
assert_contains "$verifier_output" 'sway not found'
assert_contains "$verifier_output" 'waybar not found'
assert_contains "$verifier_output" 'Dotfiles Sway login session missing'
selected_absent_failures="$verifier_failures"
((selected_absent_failures > unselected_failures)) ||
  _test_die "a selected but uninstalled Sway session added no failure ($selected_absent_failures vs $unselected_failures)"
printf 'PASS: a selected Sway session that was never installed is reported, not skipped\n'

# ... and depositing the artifact must not be what decides it. The same
# recorded selection with a sway config present must reach the same section.
new_machine base,dotnet-debug,sway
mkdir -p "$root/config/sway"
printf '# fixture\n' >"$root/config/sway/config"
run_verifier
assert_contains "$verifier_output" "$sway_section"
assert_contains "$verifier_output" 'sway not found'
printf 'PASS: the Sway verdict does not turn on whether the config file happens to exist\n'

# The artifact arm stays, so a machine that never selected Sway but still has
# its configuration is asked about it rather than passing silently.
new_machine base,dotnet-debug
mkdir -p "$root/config/sway"
printf '# fixture\n' >"$root/config/sway/config"
run_verifier
assert_contains "$verifier_output" "$sway_section"
printf 'PASS: a leftover Sway configuration on an unselected machine is still reported\n'

# KDE is the same shape with a command in place of a file: plasmashell was both
# the thing being verified and the gate deciding whether to verify it.
new_machine base,dotnet-debug,kde
run_verifier
assert_contains "$verifier_output" "$kde_section"
assert_contains "$verifier_output" 'dolphin not found'
assert_not_contains "$verifier_output" 'KDE integration is not selected'
printf 'PASS: a selected KDE integration without Plasma is reported, not skipped\n'

# ---------------------------------------------------------------------------
# GAP-12: every mise invocation runs in the deterministic context
# ---------------------------------------------------------------------------
#
# common/lib/common.sh's contract is that a caller's project configuration can
# never reach a global bootstrap, which run_mise implements by running mise
# from the neutral context directory with MISE_CEILING_PATHS set to it. The
# `mise ls` call was made bare, so it composed its answer from every mise.toml
# between the operator's working directory and the root.

new_machine base,dotnet-debug
mise_log="$root/mise-invocations.log"
mkdir -p "$root/home/.local/bin" "$root/state/dotfiles/mise-context"
cat >"$root/home/.local/bin/mise" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s|%s|%s\n' "$1" "$PWD" "${MISE_CEILING_PATHS:-<unset>}" \
  >>"${MISE_INVOCATION_LOG:?}"
exit 0
EOF
chmod +x "$root/home/.local/bin/mise"

# A project configuration in the directory the verifier is started from. A bare
# invocation reads it; one made through run_mise cannot see past the ceiling.
caller_project="$root/caller-project"
mkdir -p "$caller_project"
printf '[tools]\nsentinel = "1"\n' >"$caller_project/mise.toml"

(
  cd "$caller_project"
  run_verifier "MISE_INVOCATION_LOG=$mise_log"
)
assert_path_exists "$mise_log"
assert_contains "$(cut -d'|' -f1 "$mise_log")" 'ls'

context_dir="$root/state/dotfiles/mise-context"
while IFS='|' read -r verb directory ceiling; do
  [[ "$directory" == "$context_dir" ]] ||
    _test_die "mise $verb ran in $directory, not the deterministic context $context_dir"
  [[ "$ceiling" == "$context_dir" ]] ||
    _test_die "mise $verb ran with MISE_CEILING_PATHS=$ceiling, not $context_dir"
done <"$mise_log"
printf 'PASS: every mise invocation the Fedora verifier makes runs in the deterministic context\n'

# The same rule read off the source, so a new call added later is caught
# whether or not a fixture happens to reach it. Command position only: naming
# the executable in a test or an assignment is not an invocation.
#
# Scoped to this verifier on purpose. platforms/macos/scripts/verify.sh and
# platforms/parrot-ctf/scripts/verify.sh each still carry one bare invocation
# of the same shape (`mise activate bash` and `mise exec -- nvim`), and those
# files belong to other work; widening this reader is for whoever fixes them.
# mise_invocations <file>: the lines that use $mise_command as a command, with
# the two places that only name it -- a [[ ]] test and an assignment -- removed
# first, so what is left is an invocation.
mise_invocations() {
  sed -e 's/\[\[[^]]*\]\]//g' \
    -e 's/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="\$mise_command"[[:space:]]*$//' "$1" |
    grep -nE '"\$mise_command"' | grep -v run_mise || true
}

assert_eq "" "$(mise_invocations "$verifier")" \
  'the Fedora verifier invokes mise outside run_mise'

# ... and the reader can fail, which the tree gives it no chance to show.
planted_verifier="$root/planted-verify.sh"
{
  cat "$verifier"
  printf '\n%s\n' '"$mise_command" ls >/dev/null 2>&1 || true'
} >"$planted_verifier"
planted="$(mise_invocations "$planted_verifier")"
assert_contains "$planted" '"$mise_command" ls'
printf 'PASS: the reader reports a planted bare mise invocation\n'

# ---------------------------------------------------------------------------
# #369: a Stow link is checked against the exact file Stow should have linked
# ---------------------------------------------------------------------------
#
# The containment guarantee alone accepted a link redirected at any other file
# in the same package. Each call site now names its source, and the two
# assertions below are about the call sites themselves: the names have to be
# real, and they have to be inside the root the same call already declares.
# Neither can be satisfied by a plausible-looking path that no longer exists.

# The calls span continuation lines, so they are rejoined before being read.
mapfile -t symlink_calls < <(
  awk '
    { line = line $0 }
    /\\$/ { sub(/\\$/, " ", line); next }
    { print line; line = "" }
  ' "$verifier" |
    grep -E '^[[:space:]]*check_symlink ' | sed 's/^[[:space:]]*//'
)
((${#symlink_calls[@]} > 0)) ||
  _test_die 'no check_symlink call was read out of the Fedora verifier, so this check proves nothing'

# expand_call <call> <flavour>: the call's arguments as Bash would split them,
# one per line, with the repository paths resolved against this checkout.
expand_call() {
  (
    # Read by the eval below, which is the call's own source text.
    # shellcheck disable=SC2034
    DOTFILES_ROOT="$repo_root"
    # shellcheck disable=SC2034
    flavour="$2"
    # The link side names a machine, not this checkout; a sentinel keeps the
    # arguments well-formed without an unset variable ending the subshell.
    HOME="/nonexistent-fixture-home"
    # shellcheck disable=SC2034
    XDG_CONFIG_HOME="$HOME/.config"
    # shellcheck disable=SC2034
    XDG_DATA_HOME="$HOME/.local/share"
    eval "set -- $1"
    shift
    printf '%s\n' "$@"
  )
}

checked_sources=0
for call in "${symlink_calls[@]}"; do
  flavours=(mocha)
  [[ "$call" != *'${flavour}'* ]] || flavours=(latte frappe macchiato mocha)
  for flavour in "${flavours[@]}"; do
    mapfile -t call_arguments < <(expand_call "$call" "$flavour")
    ((${#call_arguments[@]} == 3)) ||
      _test_die "check_symlink names no Stow source, so it can only prove containment: $call"
    expected_root="${call_arguments[1]%/}"
    expected_source="${call_arguments[2]}"
    [[ -e "$expected_source" ]] ||
      _test_die "check_symlink names a Stow source this checkout does not have: $expected_source"
    [[ "$expected_source" == "$expected_root/"* ]] ||
      _test_die "check_symlink names a source outside the package it declares: $expected_source is not under $expected_root"
    checked_sources=$((checked_sources + 1))
  done
done
printf 'PASS: all %d Stow sources the Fedora verifier names exist under the package it declares\n' \
  "$checked_sources"

# And the guarantee is live, not only well-spelled: a link into the right
# package but at the wrong file must fail. ghostty carries more than one file,
# so the mislink stays inside the package root the same call declares.
new_machine base,dotnet-debug
mkdir -p "$root/config/ghostty"
ln -sf "$repo_root/ghostty/.config/ghostty/shared.conf" "$root/config/ghostty/config"
run_verifier
assert_contains "$verifier_output" 'is not the file Stow should have linked'
assert_contains "$verifier_output" "$repo_root/ghostty/.config/ghostty/config"
printf 'PASS: a link into the right package but at the wrong file fails verification\n'

printf '\nFedora verification tests passed.\n'
