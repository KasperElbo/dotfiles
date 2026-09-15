#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/common.sh
source "$repo_root/common/lib/common.sh"
# shellcheck source=../common/lib/preflight.sh
source "$repo_root/common/lib/preflight.sh"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"
package_root="$test_root/packages"; HOME="$test_root/home"; export HOME
mkdir -p "$package_root/one/.config/app" "$package_root/two/.local/bin" "$HOME/.config/app" "$HOME/.local/bin"
printf 'one\n' >"$package_root/one/.config/app/one"
printf 'two\n' >"$package_root/two/.local/bin/two"
ln -s "$package_root/one/.config/app/one" "$HOME/.config/app/one"
preflight_stow_packages "$package_root::one"

rm "$HOME/.config/app/one"
printf 'preserve\n' >"$HOME/.config/app/one"
ln -s "$test_root/missing" "$HOME/.local/bin/two"
before="$(sha256sum "$HOME/.config/app/one")"
if preflight_stow_packages "$package_root::one" "$package_root::two" 2>"$test_root/conflicts"; then
  printf 'Conflicting Stow plan unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'Stow conflict [one]' "$test_root/conflicts"
grep -Fq 'Stow conflict [two]' "$test_root/conflicts"
[[ "$(sha256sum "$HOME/.config/app/one")" == "$before" ]]

mkdir -p "$package_root/three/.config/other" "$test_root/other-checkout"
printf 'three\n' >"$package_root/three/.config/other/file"
printf 'other\n' >"$test_root/other-checkout/file"
mkdir -p "$HOME/.config/other"
ln -s "$test_root/other-checkout/file" "$HOME/.config/other/file"
if preflight_stow_packages "$package_root::three" 2>"$test_root/wrong-checkout"; then
  printf 'Wrong-checkout Stow link unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'link owned by another checkout or source' "$test_root/wrong-checkout"

rm -rf "$HOME/.config"
printf 'parent\n' >"$HOME/.config"
if preflight_stow_packages "$package_root::one" 2>"$test_root/parent"; then
  printf 'Parent-path conflict unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'parent path is not a real directory' "$test_root/parent"

# A conflict in the final Fedora Stow package must stop before DNF or lifecycle
# state. This exercises the top-level ordering, not only the inspector helper.
integration_home="$test_root/integration-home"
integration_config="$test_root/integration-config"
mock_bin="$test_root/bin"
mkdir -p "$integration_home" "$integration_config" "$mock_bin"
test_stub_init "$test_root"
test_stub_install "$test_root" dnf
test_stub_install "$test_root" sudo
test_stub_install "$test_root" systemctl
test_stub_allow "$test_root" sudo -n -v
late_source="$(find "$repo_root/platforms/fedora/stow/theme-assets" -type f | head -n 1)"
late_relative="${late_source#"$repo_root/platforms/fedora/stow/theme-assets/"}"
mkdir -p "$(dirname "$integration_home/$late_relative")"
printf 'user-owned-late-conflict\n' >"$integration_home/$late_relative"
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -u) printf '1000\n' ;; -un) printf 'tester\n' ;; *) /usr/bin/id "$@" ;; esac
EOF
cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "${SUDO_NOAUTH:-}" == true && "$*" == '-n -v' ]] && exit 1
exit 0
EOF
cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$mock_bin"/* "$test_root/handlers/sudo"
printf 'ID=fedora\n' >"$test_root/os-release"
if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/noauth-state" PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" \
  SUDO_NOAUTH=true "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/noauth" 2>&1; then
  printf 'Missing non-interactive sudo authorization unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'requires cached sudo authorization' "$test_root/noauth"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/noauth-state/dotfiles/install.conf" ]]

if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/integration-state" PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" \
  "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/integration" 2>&1; then
  printf 'Top-level late Stow conflict unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq 'Stow conflict [theme-assets]' "$test_root/integration"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/integration-state/dotfiles/install.conf" ]]
grep -Fqx 'user-owned-late-conflict' "$integration_home/$late_relative"

# The same late conflict against a manifest whose header lost the stow column
# must stop preflight naming the column, not skip the conflict check and apply.
sed '1s/\tstow\t/\tstow_packages\t/' "$repo_root/config/capabilities.tsv" >"$test_root/stow-renamed.tsv"
if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/stow-renamed-state" PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" CAPABILITY_MANIFEST="$test_root/stow-renamed.tsv" \
  "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/stow-renamed" 2>&1; then
  printf 'A capability manifest without a stow column unexpectedly passed preflight.\n' >&2; exit 1
fi
grep -Fq 'has no column: stow' "$test_root/stow-renamed"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/stow-renamed-state/dotfiles/install.conf" ]]
grep -Fqx 'user-owned-late-conflict' "$integration_home/$late_relative"
printf 'Complete non-mutating Stow preflight passed.\n'

# Each installer resolves its selected capability set in one function, read by
# the selection check, preflight and the lifecycle record that ./doctor and
# --rerun trust (issue #243). A second hand-written "$flag:capability" loop
# could drop a capability from the record alone, and doctor would then report
# that capability's installed state as residual.
assert_single_capability_selection() {
  local installer="$1" function="$2" loops readers
  loops="$(grep -c 'for selection in' "$installer" || true)"
  readers="$(grep -cF "< <($function)" "$installer" || true)"
  grep -q "^$function() " "$installer" || {
    printf '%s does not define %s.\n' "$installer" "$function"
    return 1
  }
  ((loops <= 1)) || {
    printf '%s resolves its selected capabilities in %d loops; resolve them once, in %s.\n' \
      "$installer" "$loops" "$function"
    return 1
  }
  ((readers == 3)) || {
    printf '%s reads %s %d times; the selection check, preflight and the lifecycle record must each read it.\n' \
      "$installer" "$function" "$readers"
    return 1
  }
}
for platform_selection in fedora:fedora_selected_capabilities fedora-wsl:wsl_selected_capabilities \
  macos:macos_selected_capabilities parrot-ctf:parrot_selected_capabilities; do
  assert_single_capability_selection "$repo_root/platforms/${platform_selection%%:*}/install.sh" \
    "${platform_selection#*:}"
done

# Negative control: restore the second, record-only loop in a scratch copy.
duplicated_installer="$test_root/fedora-install-with-second-selection.sh"
python3 - "$repo_root/platforms/fedora/install.sh" "$duplicated_installer" <<'EOF'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
reader = 'while IFS= read -r capability; do capabilities+="${capabilities:+,}$capability"; done < <(fedora_selected_capabilities)'
loop = ('capabilities="base,dotnet-debug"; for selection in "$bool_kde:kde" "$install_ai:ai"; do '
        '[[ "${selection%%:*}" != true ]] || capabilities+=",${selection#*:}"; done')
assert source.count(reader) == 1, "lifecycle record reader not found"
open(sys.argv[2], "w", encoding="utf-8").write(source.replace(reader, loop))
EOF
if assert_single_capability_selection "$duplicated_installer" fedora_selected_capabilities \
  >"$test_root/duplicated-selection" 2>&1; then
  printf 'A second capability selection loop unexpectedly passed.\n' >&2; exit 1
fi
grep -Fq "$duplicated_installer resolves its selected capabilities in 2 loops" "$test_root/duplicated-selection"
printf 'Single capability selection guard passed.\n'
