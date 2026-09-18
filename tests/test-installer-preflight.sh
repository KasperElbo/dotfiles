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
# Every installer run below decides on a stubbed figure, never on the free
# space of the machine running the tests; the cases that mean to exercise a
# full disk replace this stub and restore it afterwards.
stub_roomy_df() { test_stub_roomy_df "$mock_bin"; }
stub_roomy_df
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
# The preflight, capability and installer-selection libraries are each correct
# sourced alone, without lib/common.sh first. preflight.sh used to report a
# present command as missing, because command_exists lives in common.sh.
standalone_providers="$test_root/standalone-providers.tsv"
printf 'platform\tcommand\tprovider\towner\trequired_by\tclassification\n' >"$standalone_providers"
printf 'fedora\tls\tcoreutils\tbase\tbase\tsupported-base\n' >>"$standalone_providers"
run_standalone() {
  local library="$1" probe="$2"
  run_capture env COMMAND_PROVIDER_MANIFEST="$standalone_providers" \
    bash -c 'set -euo pipefail; source "$1"; eval "$2"' standalone \
    "$repo_root/common/lib/$library" "$probe"
  assert_not_contains "$TEST_OUTPUT" 'command not found'
  assert_not_contains "$TEST_OUTPUT" 'unbound variable'
}
run_standalone preflight.sh 'preflight_platform_command_providers fedora'
assert_success
assert_not_contains "$TEST_OUTPUT" 'Missing'
run_standalone capabilities.sh 'printf "%s\n" "$CAPABILITY_MANIFEST"; capability_field fedora base provider'
assert_success
assert_eq "$repo_root/config/capabilities.tsv"$'\n'"dnf+terra" "$TEST_OUTPUT"
run_standalone install-selection.sh 'printf "%s\n" "$INSTALL_OPTION_MANIFEST"; install_selection_set theme mocha'
assert_status 1
assert_contains "$TEST_OUTPUT" "$repo_root/config/install-options.tsv"
assert_contains "$TEST_OUTPUT" 'install_selection_set requires install_selection_reset first'
printf 'Standalone preflight, capability and selection libraries passed.\n'

# Disk space and reachability are checked before any mutating step, and only
# for a download the run is certain to make.
probe_bin="$test_root/probe-bin"
mkdir -p "$probe_bin"
cat >"$probe_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/full-disk 102400000 102398976 1024 100%% /\n'
EOF
chmod +x "$probe_bin/df"
run_preflight_probe() {
  run_capture env PATH="$probe_bin:$PATH" bash -c \
    'set -uo pipefail; source "$1"; shift; "$@"' probe \
    "$repo_root/common/lib/preflight.sh" "$@"
}

run_preflight_probe preflight_disk_space "$test_root/not-created-yet" 2048
assert_failure
assert_contains "$TEST_OUTPUT" \
  "Not enough free disk space for $test_root/not-created-yet: 1 MiB available, 2048 MiB required"
rm -- "$probe_bin/df"
run_preflight_probe preflight_disk_space "$test_root" 1
assert_success

# The floor is stated in MiB but df answers in its own block size, and the two
# implementations this repository installs on disagree about which one -P
# selects: GNU df honours a block-size flag, while Apple's df documents -P as
# overriding the block size to 512-byte counts. Each stub answers the flags the
# way its real implementation does, so the same free space must produce the
# same decision from both; a run that asks for a unit only one of them honours
# reads 500 MiB as gigabytes on the other and never refuses.
stub_df() {
  local posix_unit="$1"
  cat >"$probe_bin/df" <<EOF
#!/usr/bin/env bash
unit=$posix_unit
for argument in "\$@"; do
  case "\$argument" in
  -*k*) unit=1024 ;;
  ${2:-}
  esac
done
printf 'Filesystem blocks Used Available Capacity Mounted on\n'
printf '/dev/stub 0 0 %s 50%% /\n' "\$((\${PROBE_FREE_MIB:?} * unit))"
EOF
  chmod +x "$probe_bin/df"
}
stub_df_gnu() { stub_df 1024 '-*m*) unit=1 ;;'; }
stub_df_apple() { stub_df 2048; }

for shape in gnu apple; do
  "stub_df_$shape"
  PROBE_FREE_MIB=500 run_preflight_probe preflight_disk_space "$test_root" 2048
  assert_failure
  assert_contains "$TEST_OUTPUT" '500 MiB available, 2048 MiB required'
  PROBE_FREE_MIB=500 run_preflight_probe preflight_disk_space "$test_root" 400
  assert_success
done
rm -- "$probe_bin/df"

cat >"$probe_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit "${PROBE_CURL_STATUS:?}"
EOF
chmod +x "$probe_bin/curl"
# 7 is curl's "could not connect": no network path to the host.
PROBE_CURL_STATUS=7 run_preflight_probe preflight_network \
  https://example.invalid/installer.sh 'the example installer'
assert_failure
assert_contains "$TEST_OUTPUT" \
  'Cannot reach the example installer, which this installation downloads from: https://example.invalid/installer.sh'
# 60 is curl's "peer certificate did not verify": the TLS session the real
# download needs cannot be established, so the run must refuse here rather
# than fail partway through the first mutating step.
PROBE_CURL_STATUS=60 run_preflight_probe preflight_network \
  https://example.invalid/installer.sh 'the example installer'
assert_failure
assert_contains "$TEST_OUTPUT" \
  'Cannot reach the example installer, which this installation downloads from: https://example.invalid/installer.sh'
# 22 is an HTTP error answer, which still proves the network path works.
PROBE_CURL_STATUS=22 run_preflight_probe preflight_network \
  https://example.invalid/installer.sh 'the example installer'
assert_success

# A host that connects at once and answers slowly is reachable, not refused.
# The probe's connect bound and its total ceiling are separate budgets: this
# curl honours the ones it is handed, the way the real one does -- --max-time
# bounds the whole operation, so an answer that arrives within the ceiling
# passes even though it took far longer than the connect bound allows.
cat >"$probe_bin/curl" <<'EOF'
#!/usr/bin/env bash
max_time=0
while (($#)); do
  [[ "$1" != --max-time ]] || max_time="$2"
  shift
done
delay="${PROBE_RESPONSE_DELAY:?}"
if ((delay > max_time)); then
  sleep "$max_time"
  exit 28
fi
sleep "$delay"
EOF
chmod +x "$probe_bin/curl"
PROBE_RESPONSE_DELAY=3 DOTFILES_FETCH_PROBE_TIMEOUT=1 DOTFILES_FETCH_PROBE_MAX_TIME=10 \
  run_preflight_probe preflight_network \
  https://example.invalid/installer.sh 'the example installer'
assert_success
# The ceiling still bounds the probe: a host whose answer does not complete
# within it exits 28, so an offline machine is still refused in seconds.
PROBE_RESPONSE_DELAY=5 DOTFILES_FETCH_PROBE_TIMEOUT=1 DOTFILES_FETCH_PROBE_MAX_TIME=2 \
  run_preflight_probe preflight_network \
  https://example.invalid/installer.sh 'the example installer'
assert_failure
assert_contains "$TEST_OUTPUT" \
  'Cannot reach the example installer, which this installation downloads from: https://example.invalid/installer.sh'

# The same failure stops the top-level plan before DNF or lifecycle state.
cat >"$mock_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/full-disk 102400000 102398976 1024 100%% /\n'
EOF
chmod +x "$mock_bin/df"
if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/disk-state" PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" \
  "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/disk" 2>&1; then
  printf 'A full disk unexpectedly passed preflight.\n' >&2; exit 1
fi
grep -Fq 'Not enough free disk space' "$test_root/disk"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/disk-state/dotfiles/install.conf" ]]
stub_roomy_df
printf 'Disk-space and reachability preflight passed.\n'

# The system floor is measured where the package-manager transaction and its
# download cache land, not on the filesystem carrying the user's data. A
# supported split-/var layout, roomy where this run's HOME lives and full where
# DNF caches, must still be refused before the first mutating step. The answer
# is chosen by this run's own root rather than by a /var prefix, because
# TMPDIR itself is under /var on macOS and on any host that sets /var/tmp.
cat >"$mock_bin/df" <<EOF
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "\${!#}" in
"$test_root"/*) printf '/dev/home-volume 102400000 20480000 81920000 20%% /home\n' ;;
*) printf '/dev/var-volume 102400000 102398976 1024 100%% /var\n' ;;
esac
EOF
chmod +x "$mock_bin/df"
if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/var-state" \
  XDG_DATA_HOME="$integration_home/.local/share" \
  PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" \
  "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/var-disk" 2>&1; then
  printf 'A full /var unexpectedly passed preflight on a roomy home.\n' >&2; exit 1
fi
grep -Fq 'Not enough free disk space for /var/cache/dnf: 1 MiB available' "$test_root/var-disk"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/var-state/dotfiles/install.conf" ]]
stub_roomy_df
printf 'System disk floor is measured on the package-manager filesystem.\n'

# The network half refuses the same way. This machine has no Terra repository,
# so the run is certain to download from one; an unreachable host must stop the
# run ahead of install_lifecycle_begin and the first DNF transaction rather
# than partway through it.
cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$*" in '-q terra-release') exit 1 ;; esac
exit 0
EOF
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$mock_bin/rpm" "$mock_bin/curl"
if HOME="$integration_home" XDG_CONFIG_HOME="$integration_config" \
  XDG_STATE_HOME="$test_root/offline-state" PATH="$mock_bin:$PATH" \
  OS_RELEASE_FILE="$test_root/os-release" \
  "$repo_root/install.sh" --no-kde --no-latex --non-interactive \
  >"$test_root/offline" 2>&1; then
  printf 'An unreachable Terra repository unexpectedly passed preflight.\n' >&2; exit 1
fi
grep -Fq 'Cannot reach the Terra repository' "$test_root/offline"
assert_file_empty "$test_root/logs/dnf.log"
[[ ! -e "$test_root/offline-state/dotfiles/install.conf" ]]
printf 'An unreachable download host refuses before anything is changed.\n'
