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
  local passes="$1" failures="$2" warnings="$3"
  assert_eq "$passes" "$VERIFY_PASSES" "verifier pass count"
  assert_eq "$failures" "$VERIFY_FAILURES" "verifier failure count"
  assert_eq "$warnings" "$VERIFY_WARNINGS" "verifier warning count"
}

printf 'Verifier outcome contract\n'
verify_reset
warning "informational drift"
finish_verification "Fixture" >/dev/null
assert_verifier_counts 0 0 1

verify_reset
fail "owned invariant failed" || true
if finish_verification "Fixture" >/dev/null 2>&1; then
  _test_die "a failed owned invariant must make the final result non-zero"
fi
assert_verifier_counts 0 1 0

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
        local e=off u=off p
        case "$-" in *e*) e=on ;; esac
        case "$-" in *u*) u=on ;; esac
        p="$(set -o pipefail)"
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
