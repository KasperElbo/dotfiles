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
mkdir -p "$root/mason-data/nvim/mason/packages/lua-language-server"
printf '# tools\nlua-language-server\n\nstylua\n' >"$root/mason-inventory.txt"

verify_reset
XDG_DATA_HOME="$root/mason-data" check_mason_inventory "$root/mason-inventory.txt" \
  >"$root/mason.out" 2>&1 || true
assert_verifier_counts 1 1 0
assert_file_contains "$root/mason.out" 'Mason package not installed: stylua'

mkdir -p "$root/mason-data/nvim/mason/packages/stylua" \
  "$root/mason-data/nvim/mason/packages/untracked-tool"
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
assert_verifier_counts 1 1 0
assert_file_contains "$root/tmux.out" "Catppuccin tmux is not at the pinned $tmux_pin"

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

printf 'Shared verifier tests passed.\n'
