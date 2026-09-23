#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/verify.sh
source "$repo_root/common/lib/verify.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"

# A counted check runs inside run_capture's command substitution, so its
# counter increments never reach this shell. Probes that need the counts print
# them from inside instead, and assert_probe_counts reads that line back.
probe_counts() {
  "$@"
  printf 'counts %d %d %d %d\n' \
    "$VERIFY_PASSES" "$VERIFY_FAILURES" "$VERIFY_WARNINGS" "$VERIFY_NOT_OBSERVED"
}

assert_probe_counts() {
  assert_contains "$TEST_OUTPUT" "counts $1 $2 $3 $4"
}

assert_verifier_counts() {
  local passes="$1" failures="$2" warnings="$3" not_observed="${4:-0}"
  assert_eq "$passes" "$VERIFY_PASSES" "verifier pass count"
  assert_eq "$failures" "$VERIFY_FAILURES" "verifier failure count"
  assert_eq "$warnings" "$VERIFY_WARNINGS" "verifier warning count"
  assert_eq "$not_observed" "$VERIFY_NOT_OBSERVED" "verifier not-observed count"
}

printf 'Verifier outcome contract\n'
verify_reset
warning "informational drift"
finish_verification "Fixture" >/dev/null
assert_verifier_counts 0 0 1

verify_reset
not_observed "hosted CI cannot change this host precondition"
summary="$(finish_verification "Fixture")"
assert_verifier_counts 0 0 0 1
assert_contains "$summary" "Fixture completed with unobserved checks:"
assert_contains "$summary" "1 unobserved check(s)"
assert_not_contains "$summary" "Fixture passed"

verify_reset
warning "informational drift"
not_observed "hosted CI cannot change this host precondition"
summary="$(finish_verification "Fixture")"
assert_verifier_counts 0 0 1 1
assert_contains "$summary" "Fixture completed with warnings and unobserved checks:"
assert_contains "$summary" "1 warning(s), 1 unobserved check(s)"

verify_reset
fail "owned invariant failed" || true
not_observed "another host precondition is unavailable"
run_capture finish_verification "Fixture"
if ((TEST_STATUS == 0)); then
  _test_die "a failed owned invariant must make the final result non-zero"
fi
assert_verifier_counts 0 1 0 1
assert_contains "$TEST_OUTPUT" "Fixture failed:"
assert_contains "$TEST_OUTPUT" "1 failure(s), 0 warning(s), 1 unobserved check(s)"

printf 'Portable Stow ownership\n'
mkdir -p "$root/repo/pkg/config" "$root/other/pkg/config" \
  "$root/repo-other/pkg/config" "$root/home"
printf 'managed\n' >"$root/repo/pkg/config/file"
printf 'other\n' >"$root/other/pkg/config/file"
printf 'prefix\n' >"$root/repo-other/pkg/config/file"

ln -s ../repo/pkg/config/file "$root/home/relative"
verify_reset
check_symlink "$root/home/relative" "$root/repo/pkg"
assert_verifier_counts 1 0 0

ln -s "$root/repo/pkg/config/file" "$root/home/absolute"
verify_reset
check_symlink "$root/home/absolute" "$root/repo/pkg"
assert_verifier_counts 1 0 0

ln -s "$root/repo/pkg/config/missing" "$root/home/dangling"
verify_reset
check_symlink "$root/home/dangling" "$root/repo/pkg" || true
assert_verifier_counts 0 1 0

ln -s "$root/other/pkg/config/file" "$root/home/other-checkout"
verify_reset
check_symlink "$root/home/other-checkout" "$root/repo/pkg" || true
assert_verifier_counts 0 1 0

ln -s "$root/repo-other/pkg/config/file" "$root/home/similar-prefix"
verify_reset
check_symlink "$root/home/similar-prefix" "$root/repo" || true
assert_verifier_counts 0 1 0

printf 'plain\n' >"$root/home/plain"
verify_reset
check_symlink "$root/home/plain" "$root/repo/pkg" || true
assert_verifier_counts 0 1 0
assert_eq "plain" "$(cat "$root/home/plain")" "regular-file negative check must not modify the path"

# --- The exact Stow source --------------------------------------------------
#
# Containment proves the link points somewhere below the right package, which
# a link redirected at another file in the SAME package also satisfies: a
# manual mislink, a faulty migration or a Stow-layout regression could send a
# configuration path at the wrong repository file and be reported green
# (issue #369). A third argument makes the final test exact identity.
printf 'Exact Stow source\n'

printf 'readme\n' >"$root/repo/pkg/README"
source_file="$root/repo/pkg/config/file"
# The message names canonical paths on both sides, and on macOS the test root
# lives under $TMPDIR, which is /var/folders/... -- a symlink to
# /private/var/folders/... So the expectation is canonicalized the same way the
# helper canonicalizes it, or this suite passes on Linux and fails on macOS for
# a reason that has nothing to do with what it is testing.
canonical_source="$(resolve_existing_path "$source_file")"

ln -s "$source_file" "$root/home/exact-absolute"
verify_reset
check_symlink "$root/home/exact-absolute" "$root/repo/pkg" "$source_file"
assert_verifier_counts 1 0 0

# The same source spelled relatively, and reached through a symlinked parent:
# both sides are canonicalized, so neither spelling changes the answer.
ln -s ../repo/pkg/config/file "$root/home/exact-relative"
ln -sfn "$root/repo" "$root/repo-link"
verify_reset
check_symlink "$root/home/exact-relative" "$root/repo/pkg" \
  "$root/repo-link/pkg/config/file"
assert_verifier_counts 1 0 0

# The reproduction from the issue: the intended source and an unrelated file
# in the same package, with the link pointing at the wrong one. Containment
# alone reported this as owned.
ln -s "$root/repo/pkg/README" "$root/home/wrong-file-same-package"
verify_reset
run_capture probe_counts check_symlink "$root/home/wrong-file-same-package" \
  "$root/repo/pkg" "$source_file"
assert_contains "$TEST_OUTPUT" 'is not the file Stow should have linked'
assert_contains "$TEST_OUTPUT" "expected=$canonical_source"
assert_probe_counts 0 1 0 0

# A source that is not in this checkout at all is a failure naming it, rather
# than an equality against the empty string that no link could satisfy or,
# worse, one that any link could.
verify_reset
run_capture probe_counts check_symlink "$root/home/exact-absolute" \
  "$root/repo/pkg" "$root/repo/pkg/config/never-written"
assert_contains "$TEST_OUTPUT" 'does not exist in this checkout'
assert_probe_counts 0 1 0 0

# The five properties the helper already had keep their verdicts and their
# wording when the exact source is supplied.
verify_reset
run_capture probe_counts check_symlink "$root/home/other-checkout" \
  "$root/repo/pkg" "$source_file"
assert_contains "$TEST_OUTPUT" 'is not owned by the expected package'
assert_probe_counts 0 1 0 0

verify_reset
run_capture probe_counts check_symlink "$root/home/dangling" \
  "$root/repo/pkg" "$source_file"
assert_contains "$TEST_OUTPUT" 'is a dangling symlink'
assert_probe_counts 0 1 0 0

verify_reset
run_capture probe_counts check_symlink "$root/home/plain" \
  "$root/repo/pkg" "$source_file"
assert_contains "$TEST_OUTPUT" 'is not a symlink'
assert_probe_counts 0 1 0 0

printf 'PASS: a link to the wrong file in the right package fails only when the exact source is given\n'

printf 'mise ownership\n'
mkdir -p "$root/mise-managed/bin" "$root/mise-data/shims" "$root/external"
cat >"$root/mise-bin" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == which && "\${2:-}" == tool ]]; then
  printf '%s\\n' "$root/mise-managed/bin/tool"
  exit 0
fi
exit 1
EOF
chmod +x "$root/mise-bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/mise-managed/bin/tool"
chmod +x "$root/mise-managed/bin/tool"

# check_mise_owned reaches mise through run_mise, which requires the
# deterministic context to already exist and to be free of tool declarations
# rather than building one itself (issue #345). An installed machine always has
# it, so the fixture provides it too -- and, by pointing XDG_STATE_HOME at the
# test root, stops these checks reaching the state directory of whoever is
# running the suite.
export XDG_STATE_HOME="$root/state"
mise_context="$XDG_STATE_HOME/dotfiles/mise-context"
mkdir -p "$mise_context"

VERIFY_MISE_COMMAND="$root/mise-bin"
MISE_DATA_DIR="$root/mise-data"
MISE_SHIMS_DIR="$root/mise-data/shims"

PATH="$root/mise-managed/bin:$PATH"
VERIFY_CALLER_PATH="$PATH"
verify_reset
check_mise_owned tool
assert_verifier_counts 1 0 0

mkdir -p "$root/configured-login-bin"
VERIFY_CONFIGURED_LOGIN_PATH="$root/configured-login-bin"
verify_reset
check_mise_owned tool || true
assert_verifier_counts 0 1 0

# The current shell resolves through mise, but a fresh login would pick up a
# non-mise duplicate first: that shadow must fail, not pass on the current PATH.
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/configured-login-bin/tool"
chmod +x "$root/configured-login-bin/tool"
VERIFY_CONFIGURED_LOGIN_PATH="$root/configured-login-bin:$root/mise-managed/bin"
verify_reset
check_mise_owned tool >"$root/login-shadow.out" 2>&1 || true
assert_verifier_counts 0 1 0
assert_file_contains "$root/login-shadow.out" \
  "tool resolves outside mise in the configured login PATH: $root/configured-login-bin/tool"
rm -f "$root/configured-login-bin/tool"

VERIFY_CONFIGURED_LOGIN_PATH=""
verify_reset
check_mise_owned tool || true
assert_verifier_counts 0 1 0
unset VERIFY_CONFIGURED_LOGIN_PATH

printf '#!/usr/bin/env bash\nexit 0\n' >"$root/mise-data/shims/tool"
chmod +x "$root/mise-data/shims/tool"
PATH="$root/mise-data/shims:${PATH#*:}"
VERIFY_CALLER_PATH="$PATH"
verify_reset
check_mise_owned tool
assert_verifier_counts 1 0 0

rm -f "$root/mise-data/shims/tool" "$root/mise-managed/bin/tool"
hash -r
verify_reset
check_mise_owned tool || true
assert_verifier_counts 0 1 0

printf '#!/usr/bin/env bash\nexit 0\n' >"$root/mise-data/shims/tool"
chmod +x "$root/mise-data/shims/tool"
PATH="$root/mise-data/shims:${PATH#*:}"
VERIFY_CALLER_PATH="$PATH"
hash -r
verify_reset
check_mise_owned tool || true
assert_verifier_counts 0 1 0
rm -f "$root/mise-data/shims/tool"

printf '#!/usr/bin/env bash\nexit 0\n' >"$root/mise-managed/bin/tool"
chmod +x "$root/mise-managed/bin/tool"
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/external/tool"
chmod +x "$root/external/tool"
PATH="$root/external:$root/mise-data/shims:${PATH#*:}"
VERIFY_CALLER_PATH="$PATH"
hash -r
verify_reset
check_mise_owned tool || true
assert_verifier_counts 0 1 0

printf 'Functional command probe\n'
probe_bin="$root/probe-bin"
mkdir -p "$probe_bin"
cat >"$probe_bin/working-tool" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] || exit 2
printf 'working-tool 1.0\n'
EOF
# Resolves on PATH, cannot run: what a binary with a missing shared library or
# the wrong architecture looks like to a verifier.
printf '#!/usr/bin/env bash\nprintf "error while loading shared libraries\\n" >&2\nexit 127\n' \
  >"$probe_bin/broken-tool"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$probe_bin/stdin-tool"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == -V ]]\n' >"$probe_bin/ssh"
printf '#!/usr/bin/env bash\nprintf "usage: scp [-346ABCOpqRrsTv] source target\\n" >&2\nexit 1\n' \
  >"$probe_bin/scp"
printf '#!/usr/bin/env bash\nexit 1\n' >"$probe_bin/sftp"
chmod +x "$probe_bin"/*

verify_reset
PATH="$probe_bin:$PATH" check_command broken-tool
assert_verifier_counts 1 0 0

verify_reset
PATH="$probe_bin:$PATH" check_command broken-tool --probe >"$root/probe.out" 2>&1 || true
assert_verifier_counts 0 1 0
assert_file_contains "$root/probe.out" \
  "broken-tool resolves to $probe_bin/broken-tool but does not run: 'broken-tool --version' exited 127"

verify_reset
PATH="$probe_bin:$PATH" check_command working-tool --probe
PATH="$probe_bin:$PATH" check_command stdin-tool --probe
PATH="$probe_bin:$PATH" check_command ssh --probe
PATH="$probe_bin:$PATH" check_command scp --probe
assert_verifier_counts 4 0 0

verify_reset
PATH="$probe_bin:$PATH" check_command working-tool --probe --help >/dev/null 2>&1 || true
PATH="$probe_bin:$PATH" check_command sftp --probe >"$root/probe.out" 2>&1 || true
PATH="$probe_bin:$PATH" check_command missing-tool --probe >/dev/null 2>&1 || true
PATH="$probe_bin:$PATH" check_command working-tool --unknown >/dev/null 2>&1 || true
assert_verifier_counts 0 4 0
assert_file_contains "$root/probe.out" "sftp resolves to $probe_bin/sftp but does not run"
if declare -F check_command_runs >/dev/null; then
  _test_die "check_command_runs must stay retired; check_command --probe replaces it"
fi

printf 'Enabled-and-active service contract\n'
service_bin="$root/service-bin"
mkdir -p "$service_bin"
cat >"$service_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
scope=system
if [[ "${1:-}" == --user ]]; then
  scope=user
  shift
fi
case "${1:-} ${2:-}" in
"is-enabled --quiet") units="$MOCK_ENABLED" ;;
"is-active --quiet") units="$MOCK_ACTIVE" ;;
*) exit 96 ;;
esac
[[ " $units " == *" $scope:$3 "* ]]
EOF
chmod +x "$service_bin/systemctl"

check_service() {
  local enabled="$1" active="$2"
  shift 2
  PATH="$service_bin:$PATH" MOCK_ENABLED="$enabled" MOCK_ACTIVE="$active" "$@" \
    >"$root/service.out" 2>&1 || true
}

verify_reset
check_service system:firewalld.service system:firewalld.service \
  check_system_service_enabled_and_active firewalld.service
assert_verifier_counts 1 0 0
assert_file_contains "$root/service.out" 'firewalld.service is enabled and active'

verify_reset
check_service "" system:firewalld.service \
  check_system_service_enabled_and_active firewalld.service
assert_verifier_counts 0 1 0
assert_file_contains "$root/service.out" \
  'firewalld.service is active but not enabled; it will not start after a reboot'

verify_reset
check_service system:auditd.service "" \
  check_system_service_enabled_and_active auditd.service
assert_verifier_counts 0 1 0
assert_file_contains "$root/service.out" 'auditd.service is enabled but not active'

verify_reset
check_service "" "" check_system_service_enabled_and_active auditd.service
assert_verifier_counts 0 1 0
assert_file_contains "$root/service.out" 'auditd.service is neither enabled nor active'

# The user scope is its own unit namespace: a system unit of the same name
# must not satisfy it.
verify_reset
check_service "system:podman.socket user:podman.socket" system:podman.socket \
  check_user_service_enabled_and_active podman.socket
assert_verifier_counts 0 1 0
assert_file_contains "$root/service.out" \
  'podman.socket is enabled for the user but not active'

printf 'Mason inventory\n'
mason_mock_install="$repo_root/tests/support/mason-mock-install.sh"
printf '# tools\nlua-language-server\n\nstylua\n' >"$root/mason-inventory.txt"

"$mason_mock_install" "$root/mason-data/nvim/mason" lua-language-server
verify_reset
XDG_DATA_HOME="$root/mason-data" check_mason_inventory "$root/mason-inventory.txt" \
  >"$root/mason.out" 2>&1 || true
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'Mason package not installed: stylua'

"$mason_mock_install" "$root/mason-data/nvim/mason" stylua untracked-tool
verify_reset
XDG_DATA_HOME="$root/mason-data" check_mason_inventory "$root/mason-inventory.txt" \
  >"$root/mason.out" 2>&1
assert_verifier_counts 2 0 1
assert_file_contains "$root/mason.out" \
  'Unexpected Mason package (review ownership): untracked-tool'

verify_reset
XDG_DATA_HOME="$root/mason-data" check_mason_inventory "$root/missing-inventory.txt" \
  >"$root/mason.out" 2>&1 || true
assert_verifier_counts 0 1 0

# A package directory is not an installation. Mason promotes the staged files,
# links the executables and writes mason-receipt.json last, so a directory is
# evidence that an install was started and never that one finished. Each case
# below starts from two complete installations and damages one of them in
# exactly one way; the undamaged sibling must still pass, so a check that had
# started failing everything would be caught here rather than read as strict.
mason_case_root=""
mason_case_pins="$root/mason-case-pins.txt"
printf '# no pins\n' >"$mason_case_pins"

mason_case_begin() {
  mason_case_root="$root/mason-case-$1"
  rm -rf -- "$mason_case_root"
  "$mason_mock_install" "$mason_case_root/nvim/mason" \
    'lua-language-server@3.13.9' 'stylua@2.1.0'
}

mason_case_check() {
  verify_reset
  XDG_DATA_HOME="$mason_case_root" \
    check_mason_inventory "$root/mason-inventory.txt" "$mason_case_pins" \
    >"$root/mason.out" 2>&1 || true
}

# The reproduction the audit filed: an empty package directory.
mason_case_begin empty-directory
rm -rf -- "$mason_case_root/nvim/mason/packages/stylua"
mkdir -p "$mason_case_root/nvim/mason/packages/stylua"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" \
  'Mason package stylua is not completely installed'
assert_file_contains "$root/mason.out" 'mason-receipt.json'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'

# An install interrupted after its files were promoted and linked, before the
# receipt was written: the directory holds everything except the evidence that
# the install finished.
mason_case_begin interrupted
rm -f -- "$mason_case_root/nvim/mason/packages/stylua/mason-receipt.json"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" \
  'Mason package stylua is not completely installed'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'

# The executable the receipt claims has gone from Mason's bin directory, which
# is how the package is reached.
mason_case_begin missing-binary
rm -f -- "$mason_case_root/nvim/mason/bin/stylua"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" \
  "$mason_case_root/nvim/mason/bin/stylua, which is missing or not executable"

# A receipt truncated by a full disk or a killed write is not a receipt.
mason_case_begin corrupt-receipt
printf '{"name": "sty' >"$mason_case_root/nvim/mason/packages/stylua/mason-receipt.json"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'Mason receipt is not valid JSON'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'

# An explicit pin is compared against the version the receipt records, so a
# package that exists at the wrong version is reported rather than credited.
mason_case_begin wrong-version
printf 'stylua 9.9.9\n' >"$mason_case_pins"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" \
  'Mason package stylua does not match its pin: installed at 2.1.0, but pinned to 9.9.9'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'

# ...and a complete installation at the pinned version passes, unchanged. The
# verifier is read-only, so the package tree it just read must be byte for byte
# what it was.
mason_case_begin matching-version
printf 'stylua 2.1.0\nlua-language-server 3.13.9\n' >"$mason_case_pins"
mason_case_before="$(find "$mason_case_root" -type f -exec sha256sum {} + | sort)"
[[ -n "$mason_case_before" ]] ||
  _test_die 'the Mason fixture wrote no files, so the untouched check proves nothing'
mason_case_check
assert_verifier_counts 2 0 0
assert_file_contains "$root/mason.out" 'Mason: stylua (installed at 2.1.0)'
assert_eq "$mason_case_before" \
  "$(find "$mason_case_root" -type f -exec sha256sum {} + | sort)" \
  'verifying a complete Mason installation must not change it'
printf '# no pins\n' >"$mason_case_pins"

# GAP-34. Both artifacts existing says nothing about the link joining them, so
# each case below leaves bin/stylua executable and the receipt's target file in
# place, and changes only where the link goes. The undamaged sibling must still
# pass in every one, which is what separates a check that got stricter from one
# that started failing everything.
mason_stylua_link() {
  printf '%s\n' "$mason_case_root/nvim/mason/bin/stylua"
}

# The decoy is built here rather than borrowed from the system: /bin/true is
# absent on macOS, and a dangling link would be caught by the executable test
# that was already there, so the case would stop exercising this one.
unrelated_binary="$root/unrelated-bin/true"
mkdir -p "$(dirname "$unrelated_binary")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$unrelated_binary"
chmod +x "$unrelated_binary"

mason_case_begin link-to-unrelated-binary
ln -sf "$unrelated_binary" "$(mason_stylua_link)"
[[ -x "$(mason_stylua_link)" ]] ||
  _test_die 'the repointed link must stay executable, or this case proves nothing'
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'bin/stylua resolves to'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'
printf 'PASS: a Mason executable repointed outside its package is reported\n'

# The sharpest shape: the link points at a real, executable, Mason-installed
# binary -- the other package's. Every existence test in the check is satisfied.
mason_case_begin link-to-other-package
ln -sf ../packages/lua-language-server/lua-language-server "$(mason_stylua_link)"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'lua-language-server'
assert_file_contains "$root/mason.out" 'not the'
printf 'PASS: a Mason executable pointing at another package is reported\n'

# A relative and an absolute spelling of the same file are the same file, and a
# mason root reached through a symlink is the same root. Neither may read as
# drift, or the cases above would be satisfied by a check that rejects
# everything.
mason_case_begin link-spelled-absolutely
ln -sf "$mason_case_root/nvim/mason/packages/stylua/stylua" "$(mason_stylua_link)"
mason_case_check
assert_verifier_counts 2 0 0
assert_file_contains "$root/mason.out" 'Mason: stylua (installed at 2.1.0)'
printf 'PASS: an absolutely spelled Mason link is the same link\n'

mason_case_begin link-through-symlinked-root
mason_symlinked_root="$root/mason-symlinked-root"
rm -rf -- "$mason_symlinked_root"
ln -sfn "$mason_case_root" "$mason_symlinked_root"
verify_reset
XDG_DATA_HOME="$mason_symlinked_root" \
  check_mason_inventory "$root/mason-inventory.txt" "$mason_case_pins" \
  >"$root/mason.out" 2>&1 || true
assert_verifier_counts 2 0 0
assert_file_contains "$root/mason.out" 'Mason: stylua (installed at 2.1.0)'
printf 'PASS: a Mason root reached through a symlink is the same root\n'

# A receipt that claims no executables cancelled the link check rather than
# failing it, so deleting .links -- or emptying .links.bin -- made the strictest
# part of this check disappear while the package still reported installed.
mason_case_begin receipt-without-links
mason_stylua_receipt="$mason_case_root/nvim/mason/packages/stylua/mason-receipt.json"
jq 'del(.links)' "$mason_stylua_receipt" >"$mason_stylua_receipt.edited"
mv "$mason_stylua_receipt.edited" "$mason_stylua_receipt"
rm -f -- "$(mason_stylua_link)"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'carries no links object'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'
printf 'PASS: a receipt with no links object is not a finished install\n'

# An empty links.bin cancelled the link check the same way. Mason fills it
# from the package spec's bin table, and every package this repository
# installs declares one, so a receipt that links nothing is not Mason's.
mason_case_begin receipt-with-empty-bin-links
mason_stylua_receipt="$mason_case_root/nvim/mason/packages/stylua/mason-receipt.json"
jq '.links.bin = {}' "$mason_stylua_receipt" >"$mason_stylua_receipt.edited"
mv "$mason_stylua_receipt.edited" "$mason_stylua_receipt"
rm -f -- "$(mason_stylua_link)"
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'links no executables'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'
printf 'PASS: a receipt that links nothing into bin is not a finished install\n'

# On macOS and Linux Mason makes every bin entry a symlink, including for the
# npm:, pyvenv: and dotnet: packages, whose wrapper lives inside the package.
# A plain executable of the right name is therefore something else, and it
# passed every earlier test in the check: it exists, it runs, and the receipt's
# target is still in place.
mason_case_begin link-replaced-by-plain-script
rm -f -- "$(mason_stylua_link)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$(mason_stylua_link)"
chmod +x "$(mason_stylua_link)"
[[ -x "$(mason_stylua_link)" && ! -L "$(mason_stylua_link)" ]] ||
  _test_die 'the replacement must be an executable non-link, or this case proves nothing'
mason_case_check
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'bin/stylua is not a symlink'
assert_file_contains "$root/mason.out" 'Mason: lua-language-server'
printf 'PASS: a Mason executable that is not a link is reported\n'

# The npm shape, as a real macOS receipt records it: links.bin names
# node_modules/.bin/<exec>, which npm itself made a symlink into the module.
# bin/<exec> is Mason's link to npm's link, so both sides resolve to the
# module's script and must agree; a check that stopped at the first hop, or
# that refused a target that is itself a link, would fail every npm package.
mason_case_begin npm-shaped-link
mason_npm_dir="$mason_case_root/nvim/mason/packages/stylua"
mkdir -p "$mason_npm_dir/node_modules/.bin" "$mason_npm_dir/node_modules/stylua/bin"
printf '#!/usr/bin/env node\n' >"$mason_npm_dir/node_modules/stylua/bin/stylua"
chmod +x "$mason_npm_dir/node_modules/stylua/bin/stylua"
ln -sf ../stylua/bin/stylua "$mason_npm_dir/node_modules/.bin/stylua"
ln -sf ../packages/stylua/node_modules/.bin/stylua "$(mason_stylua_link)"
mason_stylua_receipt="$mason_npm_dir/mason-receipt.json"
jq '.links.bin.stylua = "node_modules/.bin/stylua"' "$mason_stylua_receipt" \
  >"$mason_stylua_receipt.edited"
mv "$mason_stylua_receipt.edited" "$mason_stylua_receipt"
mason_case_check
assert_verifier_counts 2 0 0
assert_file_contains "$root/mason.out" 'Mason: stylua (installed at 2.1.0)'
printf 'PASS: an npm package linked through node_modules/.bin is installed\n'

# jq is how a receipt is read. There is no way to make it answer "not
# installed", so this narrows PATH to a base userland without it and requires
# the check to say so: one that skipped every package because a tool was
# missing would report a clean machine, which is the failure mode this whole
# check exists to remove.
mason_case_begin without-jq
mason_jq_free_path="$root/no-jq-bin"
mkdir -p "$mason_jq_free_path"
for mason_base_command in bash dirname sed find; do
  ln -sf "$(command -v "$mason_base_command")" "$mason_jq_free_path/$mason_base_command"
done
[[ ! -e "$mason_jq_free_path/jq" ]] ||
  _test_die 'the jq-free PATH carries jq, so this case proves nothing'
mason_jq_free_output="$(
  XDG_DATA_HOME="$mason_case_root" DOTFILES_ROOT="$repo_root" \
    PATH="$mason_jq_free_path" bash -c '
      set -uo pipefail
      # shellcheck source=../common/lib/common.sh
      source "$1/common/lib/common.sh"
      # shellcheck source=../common/lib/verify.sh
      source "$1/common/lib/verify.sh"
      check_mason_inventory "$2" "$3"
      printf "counts %s %s %s\n" \
        "$VERIFY_PASSES" "$VERIFY_FAILURES" "$VERIFY_WARNINGS"
    ' mason-jq-probe "$repo_root" "$root/mason-inventory.txt" "$mason_case_pins" 2>&1
)" || true
assert_contains "$mason_jq_free_output" 'counts 0 1 0' \
  'a Mason check without jq fails once and credits nothing'
assert_contains "$mason_jq_free_output" \
  'Mason packages cannot be verified: jq is required to read Mason receipts'

# A pin file the verifier cannot parse must stop it, not quietly stop pinning.
mason_case_begin malformed-pin
printf 'stylua 2.1.0 extra\n' >"$mason_case_pins"
mason_case_check
assert_verifier_counts 0 1 0
assert_file_contains "$root/mason.out" 'Invalid Mason version pin: stylua 2.1.0 extra'
printf '# no pins\n' >"$mason_case_pins"

# The inventory read must not depend on a Bash 4 builtin. macOS's system Bash
# is 3.2, where mapfile does not exist; `enable -n` reproduces exactly that,
# down to the "mapfile: command not found" the macOS verifier printed, so these
# cases cannot be rescued by the Bash the suite happens to run under. The whole
# check runs in a child shell because `enable -n` would otherwise outlive it.
mason_probe_path=""
mason_probe() {
  mason_status=0
  mason_output="$(
    XDG_DATA_HOME="$root/mason-data" DOTFILES_ROOT="$repo_root" \
      PATH="${mason_probe_path:+$mason_probe_path:}$PATH" bash -c '
      enable -n mapfile 2>/dev/null || true
      enable -n readarray 2>/dev/null || true
      set -uo pipefail
      # shellcheck source=../common/lib/common.sh
      source "$1/common/lib/common.sh"
      # shellcheck source=../common/lib/verify.sh
      source "$1/common/lib/verify.sh"
      check_mason_inventory "$2"
      probe_status=$?
      printf "counts %s %s %s\n" \
        "$VERIFY_PASSES" "$VERIFY_FAILURES" "$VERIFY_WARNINGS"
      exit "$probe_status"
    ' mason-probe "$repo_root" "$1" 2>&1
  )" || mason_status=$?
  assert_not_contains "$mason_output" 'mapfile: command not found' \
    'the inventory read must not need a Bash 4 builtin'
}

# A populated inventory is read, its comment and blank lines are ignored, the
# two listed packages pass, and the third package Mason holds is a warning.
mason_probe "$root/mason-inventory.txt"
assert_eq 0 "$mason_status" 'a populated inventory verifies without mapfile'
assert_contains "$mason_output" 'counts 2 0 1' \
  'two listed packages pass and the untracked one warns'
assert_contains "$mason_output" 'Mason: lua-language-server'
assert_contains "$mason_output" \
  'Unexpected Mason package (review ownership): untracked-tool'

# An inventory holding only comments and blank lines is still empty.
printf '# nothing here\n\n   \n' >"$root/mason-comments-only.txt"
mason_probe "$root/mason-comments-only.txt"
assert_eq 1 "$mason_status" 'an inventory of comments alone fails'
assert_contains "$mason_output" \
  "Mason package inventory is empty: $root/mason-comments-only.txt"

# A missing inventory keeps its own diagnostic rather than becoming an empty one.
mason_probe "$root/mason-absent.txt"
assert_eq 1 "$mason_status" 'a missing inventory fails'
assert_contains "$mason_output" \
  "Mason package inventory missing: $root/mason-absent.txt"

# An inventory that exists and is readable but cannot be read — a directory in
# its place is the reproducible case — is a read failure, not an empty
# inventory. Reading a process substitution threw sed's exit status away and
# reported this as "inventory is empty", which is the same misleading second
# failure the missing mapfile produced.
mkdir -p "$root/mason-inventory-directory"
mason_probe "$root/mason-inventory-directory"
assert_eq 1 "$mason_status" 'an unreadable inventory fails'
assert_contains "$mason_output" \
  "Mason package inventory could not be read: $root/mason-inventory-directory"
assert_not_contains "$mason_output" 'inventory is empty' \
  'a failed read must not be reported as an empty inventory'

# ...and it must not depend on sed's exit status to say so. GNU sed exits
# non-zero reading a directory; BSD sed on macOS prints nothing and exits 0, so
# a check that leaned on that status reported "inventory is empty" on exactly
# the platform this function exists to support. This stands a BSD-shaped sed in
# front of the real one and asserts the diagnostic is unchanged.
mkdir -p "$root/bsd-sed"
cat >"$root/bsd-sed/sed" <<'EOF_BSD_SED'
#!/usr/bin/env bash
# Reading a directory prints nothing and exits 0, as BSD sed does.
for argument in "$@"; do
  [[ ! -d "$argument" ]] || exit 0
done
exec sed "$@"
EOF_BSD_SED
chmod +x "$root/bsd-sed/sed"
mason_probe_path="$root/bsd-sed"
mason_probe "$root/mason-inventory-directory"
mason_probe_path=""
assert_eq 1 "$mason_status" 'an unreadable inventory fails under a BSD-shaped sed'
assert_contains "$mason_output" \
  "Mason package inventory could not be read: $root/mason-inventory-directory"
assert_not_contains "$mason_output" 'inventory is empty' \
  'the read failure must not depend on sed exiting non-zero'

printf 'Pinned Catppuccin tmux\n'
tmux_pin="$(verify_catppuccin_tmux_pin)"
assert_eq \
  "$(awk -F '\t' '$1 == "catppuccin-tmux" { print $8 }' "$repo_root/config/network-sources.tsv")" \
  "$tmux_pin" "the verifier reads the pin the installer and network-source registry declare"

plugin="$root/tmux-data/tmux/plugins/catppuccin"
mkdir -p "$plugin"
git -C "$plugin" init -q
printf '# theme\n' >"$plugin/catppuccin.tmux"
git -C "$plugin" add catppuccin.tmux
git -C "$plugin" -c user.name=Test -c user.email=test@example.invalid commit -qm theme
git -C "$plugin" tag "$tmux_pin"

verify_reset
XDG_DATA_HOME="$root/tmux-data" check_catppuccin_tmux >/dev/null 2>&1
assert_verifier_counts 2 0 0

git -C "$plugin" -c user.name=Test -c user.email=test@example.invalid \
  commit -q --allow-empty -m 'past the pin'
verify_reset
XDG_DATA_HOME="$root/tmux-data" check_catppuccin_tmux >"$root/tmux.out" 2>&1 || true
assert_verifier_counts 1 0 1
assert_file_contains "$root/tmux.out" "Catppuccin tmux is at $tmux_pin-1-g"
assert_file_contains "$root/tmux.out" "not the pinned $tmux_pin"

rm -f "$plugin/catppuccin.tmux"
verify_reset
XDG_DATA_HOME="$root/tmux-data" check_catppuccin_tmux >"$root/tmux.out" 2>&1 || true
assert_verifier_counts 0 1 0
assert_file_contains "$root/tmux.out" 'Catppuccin tmux is missing'

printf 'Verifiers share one reporting contract\n'
for verifier in "$repo_root"/platforms/*/scripts/verify*.sh; do
  relative="${verifier#"$repo_root/"}"
  if [[ "$relative" == platforms/fedora/scripts/verify-parrot-isolation.sh ]]; then
    # A host-side argument wrapper that hands off to
    # verify-parrot-isolation.py; it reports nothing itself.
    if grep -Eq '^[[:space:]]*(pass|fail|warning) ' "$verifier"; then
      _test_die "$relative now reports results, so it must use common/lib/verify.sh"
    fi
    continue
  fi
  if grep -Eq '^[[:space:]]*(pass|fail|warning|section)[[:space:]]*\(\)' "$verifier"; then
    _test_die "$relative defines its own reporting helpers instead of using common/lib/verify.sh"
  fi
  grep -Eq '^[[:space:]]*source .*common/lib/verify\.sh"$' "$verifier" ||
    _test_die "$relative does not source common/lib/verify.sh"
done
printf 'PASS: every platform verifier reports through common/lib/verify.sh\n'

printf 'Common-library shell-option invariance\n'
for library in common/lib/*.sh; do
  for policy in none strict errexit nounset pipefail; do
    case "$policy" in
    none) option_command='set +e +u; set +o pipefail' ;;
    strict) option_command='set -e -u -o pipefail' ;;
    errexit) option_command='set -e; set +u; set +o pipefail' ;;
    nounset) option_command='set +e; set -u; set +o pipefail' ;;
    pipefail) option_command='set +e +u; set -o pipefail' ;;
    esac

    if ! bash --noprofile --norc -c '
      option_state() {
        local e=off u=off p=off
        case "$-" in *e*) e=on ;; esac
        case "$-" in *u*) u=on ;; esac
        if shopt -qo pipefail; then
          p=on
        fi
        printf "%s|%s|%s\\n" "$e" "$u" "$p"
      }
      DOTFILES_ROOT="$1"
      HOME="$2"
      XDG_CONFIG_HOME="$HOME/.config"
      XDG_DATA_HOME="$HOME/.local/share"
      XDG_STATE_HOME="$HOME/.local/state"
      XDG_CACHE_HOME="$HOME/.cache"
      eval "$4"
      before="$(option_state)"
      # shellcheck disable=SC1090
      source "$3"
      after="$(option_state)"
      [[ "$before" == "$after" ]]
    ' _ "$repo_root" "$root/home" "$repo_root/$library" "$option_command"; then
      _test_die "$library changed shell options under policy '$policy'"
    fi
  done
  printf 'PASS: sourcing %s preserves shell policy\n' "$library"
done

# --- Claude Code must not update itself outside mise (#281) ------------------

# A `zsh` that models a login shell reading the repository's .zshenv. The value
# it exports is chosen per case, and an unset TEST_LOGIN_DISABLE_UPDATES models
# a login that never got the setting at all.
update_root="$root/claude-updates"
mkdir -p "$update_root/bin"
cat >"$update_root/bin/zsh" <<'EOF_LOGIN_ZSH'
#!/usr/bin/env bash
set -u
if [[ $# -eq 2 && "$1" == -lc ]]; then
  if [[ -n "${TEST_LOGIN_DISABLE_UPDATES+x}" ]]; then
    export DISABLE_UPDATES="$TEST_LOGIN_DISABLE_UPDATES"
  else
    unset DISABLE_UPDATES
  fi
  exec bash -c "$2"
fi
printf 'strict login-shell fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
EOF_LOGIN_ZSH
chmod +x "$update_root/bin/zsh"

# login_environment_case <expected-outcome> [value]: the check run against a
# login shell that exports <value>, or nothing when <value> is omitted.
login_environment_case() {
  local expect="$1"
  verify_reset
  if (($# > 1)); then
    TEST_LOGIN_DISABLE_UPDATES="$2" \
      PATH="$update_root/bin:$PATH" \
      run_capture probe_counts check_login_environment DISABLE_UPDATES 1
  else
    PATH="$update_root/bin:$PATH" \
      run_capture probe_counts check_login_environment DISABLE_UPDATES 1
  fi
  assert_contains "$TEST_OUTPUT" "$expect"
}

login_environment_case 'DISABLE_UPDATES=1 in a fresh Zsh login' 1
assert_probe_counts 1 0 0 0
printf 'PASS: the setting is proved from a fresh non-interactive login\n'

login_environment_case 'DISABLE_UPDATES is unset in a fresh Zsh login'
assert_probe_counts 0 1 0 0
assert_contains "$TEST_OUTPUT" 'Restow the zsh package'
printf 'PASS: a login without the setting is a failure, with the recovery step\n'

# A login carrying some other value is not a pass. DISABLE_AUTOUPDATER, the
# variable usually reached for, stops only the background check and would leave
# `claude update` able to replace the mise-owned package, so the check has to
# insist on this variable and this value rather than on "something is set".
verify_reset
TEST_LOGIN_DISABLE_UPDATES=0 PATH="$update_root/bin:$PATH" \
  run_capture probe_counts check_login_environment DISABLE_UPDATES 1
assert_contains "$TEST_OUTPUT" "DISABLE_UPDATES is '0' in a fresh Zsh login, not 1"
assert_probe_counts 0 1 0 0
printf 'PASS: a login that sets the variable to something else is a failure\n'

# A shell that answers something unrelated -- a stub, or a login that died
# before the printf -- is a check this context could not make. Reporting it as
# an unset variable would be a false accusation.
mkdir -p "$update_root/mute"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$PATH"\n' >"$update_root/mute/zsh"
chmod +x "$update_root/mute/zsh"
verify_reset
PATH="$update_root/mute:$PATH" run_capture probe_counts check_login_environment DISABLE_UPDATES 1
assert_contains "$TEST_OUTPUT" 'the login shell did not answer'
assert_probe_counts 0 0 0 1
printf 'PASS: a shell that does not answer the probe is unobserved, not a failure\n'

# --- The block Claude Code reads itself --------------------------------------
#
# The login probe above can only speak for a shell it started. Claude Code is
# routinely launched by something that never read .zshenv, and it reads its own
# settings file whatever started it, so that file is where the block has to be.

settings_file="$update_root/settings.json"

claude_settings_case() {
  verify_reset
  run_capture probe_counts check_claude_update_settings "$settings_file" \
    DISABLE_UPDATES DISABLE_AUTOUPDATER
}

printf '{"env":{"DISABLE_UPDATES":"1","DISABLE_AUTOUPDATER":"1"},"model":"opus"}\n' \
  >"$settings_file"
claude_settings_case
assert_contains "$TEST_OUTPUT" "DISABLE_UPDATES=1 in $settings_file"
assert_contains "$TEST_OUTPUT" "DISABLE_AUTOUPDATER=1 in $settings_file"
assert_probe_counts 2 0 0 0
printf 'PASS: both keys declared in the settings file pass\n'

printf '{"env":{"DISABLE_UPDATES":"1"}}\n' >"$settings_file"
claude_settings_case
assert_contains "$TEST_OUTPUT" 'DISABLE_AUTOUPDATER is <unset>'
assert_probe_counts 1 1 0 0
printf 'PASS: one key missing is a failure naming that key\n'

# "Set to something" is not the test: the tool's gate accepts a value, and
# anything else leaves the updater free to write into the active Node prefix.
printf '{"env":{"DISABLE_UPDATES":"true","DISABLE_AUTOUPDATER":"1"}}\n' \
  >"$settings_file"
claude_settings_case
assert_contains "$TEST_OUTPUT" 'DISABLE_UPDATES is true'
assert_contains "$TEST_OUTPUT" 'not 1'
assert_probe_counts 1 1 0 0
printf 'PASS: a key set to another value is a failure, not a pass\n'

printf 'not json {\n' >"$settings_file"
claude_settings_case
assert_contains "$TEST_OUTPUT" 'is not valid JSON, so Claude Code reads no settings from it'
assert_probe_counts 0 1 0 0
printf 'PASS: an unparseable settings file is a failure\n'

rm -f "$settings_file"
claude_settings_case
assert_contains "$TEST_OUTPUT" 'does not exist, so Claude Code'"'"'s updater is unrestricted'
assert_probe_counts 0 1 0 0
printf 'PASS: a missing settings file is a failure with the recovery step\n'

# Without jq the file cannot be read, which is a check this context could not
# make. Calling it a missing block would be a false accusation.
printf '{"env":{"DISABLE_UPDATES":"1","DISABLE_AUTOUPDATER":"1"}}\n' >"$settings_file"
mkdir -p "$update_root/nojq"
for command_name in bash cat printf; do
  command_path="$(command -v "$command_name" 2>/dev/null || true)"
  [[ -z "$command_path" ]] || ln -sf "$command_path" "$update_root/nojq/$command_name"
done
verify_reset
PATH="$update_root/nojq" run_capture probe_counts \
  check_claude_update_settings "$settings_file" DISABLE_UPDATES
assert_contains "$TEST_OUTPUT" 'jq is unavailable'
assert_probe_counts 0 0 0 1
printf 'PASS: no jq is unobserved, not a failure\n'

# --- A duplicate in the active Node prefix -----------------------------------

# mise `exec -- …` runs the command with the fixture bin ahead of PATH, so the
# prefix inspected is the one this fixture models rather than the host's.
cat >"$update_root/bin/mise" <<'EOF_MISE'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == exec && "${2:-}" == -- ]] || {
  printf 'strict mise fixture rejected unsupported argv: %s\n' "$*" >&2
  exit 96
}
shift 2
exec "$@"
EOF_MISE
chmod +x "$update_root/bin/mise"
test_stub_npm_global "$update_root/bin"

duplicate_case() {
  verify_reset
  TEST_NPM_GLOBAL_PREFIX="$update_root/npm-prefix" \
    TEST_NPM_GLOBAL_PACKAGES="$1" \
    TEST_NPM_GLOBAL_STATUS="${2:-0}" \
    VERIFY_MISE_COMMAND="$update_root/bin/mise" \
    PATH="$update_root/bin:$PATH" \
    run_capture probe_counts check_no_global_npm_duplicate @anthropic-ai/claude-code @openai/codex
}

duplicate_case ""
assert_contains "$TEST_OUTPUT" 'No AI package is duplicated in the active Node prefix'
assert_probe_counts 1 0 0 0
printf 'PASS: a clean Node prefix passes\n'

duplicate_case "@anthropic-ai/claude-code"
assert_contains "$TEST_OUTPUT" '@anthropic-ai/claude-code is also installed globally with npm'
assert_contains "$TEST_OUTPUT" "$update_root/npm-prefix"
assert_contains "$TEST_OUTPUT" 'npm uninstall -g @anthropic-ai/claude-code && mise reshim'
assert_probe_counts 0 1 0 0
printf 'PASS: a global npm duplicate fails, naming the prefix and the recovery command\n'

# The dedicated mise npm-backend installation must not read as a duplicate of
# itself: it lives under the mise install tree, not the global npm prefix.
duplicate_case "some-unrelated-package"
assert_contains "$TEST_OUTPUT" 'No AI package is duplicated in the active Node prefix'
assert_probe_counts 1 0 0 0
printf 'PASS: an unrelated global package is not mistaken for an AI duplicate\n'

verify_reset
VERIFY_MISE_COMMAND="" PATH="$root/no-such-bin" \
  run_capture probe_counts check_no_global_npm_duplicate @anthropic-ai/claude-code
assert_contains "$TEST_OUTPUT" 'mise is unavailable'
assert_probe_counts 0 0 0 1
printf 'PASS: without mise the prefix is unobserved, not silently clean\n'

# --- Optional-capability dispatch: the sub-verifier's verdict ---------------
#
# verify_optional_capability is the function every optional section of the
# Fedora and Fedora WSL verifiers goes through, and the mechanism that turns
# "a selected capability's own verifier failed" into "this platform's
# verification failed" lives in its else-branch alone. Flipping that one token
# from fail to pass left the whole default suite byte-identical, and nothing in
# CI reaches the branch either: the Fedora real-install job selects only --kde
# and --sway, whose verification is inline, and the Fedora WSL job selects no
# optional capability at all (issue #383, tv-1).
#
# The two suites named after this area deliberately stay out of it.
# tests/test-optional-capability-dispatch.sh covers which disposition each pair
# of records produces and asserts that every section reaches its component
# verifier, saying in as many words that what the verifier then decides "is its
# own business and not this suite's". This is that business: the sub-verifier
# is a stub whose exit status is the fixture.
printf 'Optional-capability sub-verifier verdicts\n'

dispatch_root="$root/dispatch"
mkdir -p "$dispatch_root/state/dotfiles" "$dispatch_root/config/dotfiles"

# A machine whose last installation recorded hardening, and the component
# state a completed install of it leaves behind.
record_dispatch_selection() {
  cat >"$dispatch_root/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=$1
observed_capabilities=$1
external_assurance=not-recorded
repository=local-checkout
revision=0123456789abcdef
provenance=capability-manifest@0123456789abcdef
EOF
}

cat >"$dispatch_root/config/dotfiles/hardening.conf" <<'EOF'
schema_version=2
profile=hardening
selinux_mode=enforcing
faillock=enabled
auditd=enabled
status=installed
EOF

# The sub-verifier's exit status is the only thing that varies between cases.
dispatch_case() {
  verify_reset
  XDG_CONFIG_HOME="$dispatch_root/config" \
    XDG_STATE_HOME="$dispatch_root/state" \
    DOTFILES_ROOT="$repo_root" \
    run_capture probe_counts \
    verify_optional_capability 'Hardening profile' fedora hardening "$@"
}

record_dispatch_selection base,hardening

dispatch_case true
assert_contains "$TEST_OUTPUT" 'Hardening profile verification completed'
assert_probe_counts 1 0 0 0
printf 'PASS: a sub-verifier that succeeds is reported as completed\n'

dispatch_case false
assert_contains "$TEST_OUTPUT" 'Hardening profile verification failed'
assert_not_contains "$TEST_OUTPUT" 'Hardening profile verification completed'
assert_probe_counts 0 1 0 0
printf 'PASS: a sub-verifier that fails is counted as a failure, not a pass\n'

# The same must hold for the other disposition that dispatches. State left
# behind by a capability this machine did not select is verified anyway, with
# a warning saying so -- and a failure there is still a failure.
record_dispatch_selection base

dispatch_case false
assert_contains "$TEST_OUTPUT" 'is not selected by this machine'"'"'s recorded installation'
assert_contains "$TEST_OUTPUT" 'Hardening profile verification failed'
assert_probe_counts 0 1 1 0
printf 'PASS: a failing sub-verifier over leftover state is a failure too\n'
# --- Every check_* helper has a caller --------------------------------------
#
# check_file_mode had none, anywhere in the tree including the suites, and the
# one thing an uncalled check_* helper is guaranteed to do is sit there looking
# like coverage. It also asserted a mode without asserting a file type, so a
# directory at the checked path passed -- a trap waiting for whichever call
# site adopted it first, which would have been the sudoers drop-in's 440
# assertion (issue #396, VL-02). Deleting it is only durable if a replacement
# cannot grow back unnoticed, so the library's helpers are held to having a
# caller outside their own definition.
printf 'Shared verifier helper reachability\n'

mapfile -t verify_helpers < <(
  grep -oE '^check_[a-z0-9_]+\(\)' "$repo_root/common/lib/verify.sh" | sed 's/()$//'
)
((${#verify_helpers[@]} > 0)) ||
  _test_die 'no check_* helper was found in common/lib/verify.sh, so this audit proves nothing'

for helper in "${verify_helpers[@]}"; do
  helper_callers="$(
    git -C "$repo_root" grep -l -w -e "$helper" -- ':!common/lib/verify.sh' || true
  )"
  [[ -n "$helper_callers" ]] ||
    _test_die "$helper is defined in common/lib/verify.sh and called nowhere;" \
      "delete it rather than leaving a check that no verifier runs"
done

printf 'PASS: all %d shared check_* helpers are called by something\n' \
  "${#verify_helpers[@]}"
# --- A settings file proves the setting, not its ghost ----------------------
#
# check_file_contains reports that a theme override "matches". It used to
# prove only that the text occurred somewhere in the file, comments included,
# so one git-theme could satisfy two mutually exclusive flavour assertions at
# once and a fully commented-out override read as applied (issue #390, VL-01).
printf 'Active-line file content\n'

contains_root="$root/file-contains"
mkdir -p "$contains_root"

stale_theme="$contains_root/git-theme"
printf '[delta]\n    # features = catppuccin-latte\n    features = catppuccin-mocha\n' \
  >"$stale_theme"

verify_reset
run_capture probe_counts check_file_contains 'Delta override matches' \
  "$stale_theme" 'features = catppuccin-mocha'
assert_contains "$TEST_OUTPUT" 'Delta override matches'
assert_probe_counts 1 0 0 0
printf 'PASS: the flavour that is in effect passes, indented under its section\n'

verify_reset
run_capture probe_counts check_file_contains 'Delta override matches' \
  "$stale_theme" 'features = catppuccin-latte'
assert_contains "$TEST_OUTPUT" 'on a line that is in effect'
assert_probe_counts 0 1 0 0
printf 'PASS: the flavour left behind in a comment no longer passes as well\n'

commented_only="$contains_root/ghostty.conf"
printf '# theme = catppuccin-mocha.conf\n' >"$commented_only"

verify_reset
run_capture probe_counts check_file_contains 'Ghostty override matches' \
  "$commented_only" 'theme = catppuccin-mocha.conf'
assert_probe_counts 0 1 0 0
printf 'PASS: a file whose only match is commented out fails\n'

verify_reset
run_capture probe_counts check_file_contains 'Ghostty override matches' \
  "$contains_root/not-written-yet" 'theme = catppuccin-mocha.conf'
assert_probe_counts 0 1 0 0
printf 'PASS: an unreadable file is still a failure, not a silent pass\n'
# npm reports a dependency problem in the global tree through a non-zero exit
# while still printing the tree. Keying the not_observed branch on the status
# alone reported a run that enumerated the prefix and NAMED the duplicate as a
# run that could not happen, and the verifier exited 0 (issue #396, GAP-35).
# The same tree, twice, differing only in the exit status.
duplicate_case "@anthropic-ai/claude-code" 1
assert_contains "$TEST_OUTPUT" '@anthropic-ai/claude-code is also installed globally with npm'
assert_probe_counts 0 1 0 0
printf 'PASS: a duplicate named in the output is a failure whatever npm exited\n'

# Read, and no duplicate in it. The listing may be incomplete, so absence of a
# duplicate in it is not proof of absence either.
duplicate_case "" 1
assert_contains "$TEST_OUTPUT" 'npm exited 1 while listing the active Node prefix'
assert_probe_counts 0 0 0 1
printf 'PASS: a non-zero npm that named no duplicate is unobserved, not a pass\n'

# The branch that survives the two above: npm could not run at all, so there
# is nothing to read. mise is present; npm is not on the PATH it execs into.
mkdir -p "$update_root/mise-only"
cp "$update_root/bin/mise" "$update_root/mise-only/mise"
verify_reset
VERIFY_MISE_COMMAND="$update_root/mise-only/mise" \
  PATH="$update_root/mise-only" \
  run_capture probe_counts check_no_global_npm_duplicate @anthropic-ai/claude-code
assert_contains "$TEST_OUTPUT" 'npm produced no output under mise'
assert_probe_counts 0 0 0 1
printf 'PASS: npm that could not run at all is still unobserved\n'

# Every login probe goes through verify_login_zsh. A bare `zsh -l` inherits
# the ZDOTDIR the calling Zsh exported, reads no ~/.zshenv, and reports the
# calling terminal's environment as if a login had set it; a verifier run from
# a terminal opened before platform-env.zsh changed then failed a login that
# was correct. Comments are dropped before looking, so prose may name it.
bare_login_probes="$(
  PYTHONPATH="$repo_root/scripts/lib" python3 - "$repo_root" <<'PYTHON'
import pathlib
import re
import sys

from shell import code_text

root = pathlib.Path(sys.argv[1])
files = [root / "common/lib/verify.sh", *sorted(root.glob("common/verify-*.sh")),
         *sorted(root.glob("platforms/*/scripts/verify*.sh"))]
probe = re.compile(r"(^|[\s;&|(!`])zsh\s+-l")
for path in files:
    for number, line in enumerate(code_text(path.read_text()).splitlines(), 1):
        if probe.search(line):
            print(f"{path.relative_to(root)}:{number}: {line.strip()}")
PYTHON
)"
[[ -z "$bare_login_probes" ]] ||
  _test_die "a verifier starts a login Zsh without verify_login_zsh:"$'\n'"$bare_login_probes"
printf 'PASS: every verifier login probe goes through verify_login_zsh\n'

printf 'Shared verifier tests passed.\n'
