#!/usr/bin/env bash
# Theme precedence, capability-aware hooks and hook failure isolation (#148).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

theme_command="$repo_root/bin/.local/bin/theme"
fedora_hook="$repo_root/platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh"

# --- Fixture ---------------------------------------------------------------

# new_machine [capabilities]
#
# Builds an isolated HOME/XDG root with the Fedora theme hook installed. When
# a capability list is given, the machine also has a recorded successful
# install declaring exactly those capabilities.
new_machine() {
  local capabilities="${1:-}"

  test_new_root
  machine="$TEST_ROOT"
  mock_bin="$machine/mock-bin"
  mock_log="$machine/mock.log"
  mkdir -p "$mock_bin" "$machine/config/dotfiles/theme-hooks.d" \
    "$machine/state/dotfiles" "$machine/data"
  : >"$mock_log"

  ln -s "$fedora_hook" "$machine/config/dotfiles/theme-hooks.d/fedora.sh"

  for command_name in lookandfeeltool plasma-apply-colorscheme \
    plasma-apply-cursortheme plasma-apply-wallpaperimage kwriteconfig6; do
    cat >"$mock_bin/$command_name" <<EOF
#!/usr/bin/env bash
printf '$command_name %s\n' "\$*" >>"\$MOCK_LOG"
exit \${MOCK_KDE_EXIT:-0}
EOF
    chmod +x "$mock_bin/$command_name"
  done

  cat >"$mock_bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-t" && "$2" == "get_version" ]]; then
  [[ "${MOCK_SWAY_ACTIVE:-false}" == "true" ]] || exit 1
  exit 0
fi
printf 'swaymsg %s\n' "$*" >>"$MOCK_LOG"
EOF
  cat >"$mock_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-x ghostty" && "${MOCK_GHOSTTY_RUNNING:-false}" == "true" ]] || exit 1
printf '1234
'
EOF
  cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$mock_bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >>"$MOCK_LOG"
EOF
  cat >"$mock_bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$mock_bin"/*

  [[ -z "$capabilities" ]] || record_install "$capabilities"
}

record_install() {
  local capabilities="$1"
  cat >"$machine/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=fedora
requested_capabilities=$capabilities
observed_capabilities=$capabilities
external_assurance=not-recorded
repository=local-checkout
revision=testrevision
provenance=capability-manifest@testrevision
EOF
}

install_kde_assets() {
  local flavour
  for flavour in Latte Frappe Macchiato Mocha; do
    mkdir -p "$machine/data/plasma/look-and-feel/Catppuccin-${flavour}-Mauve"
  done
}

run_theme() {
  run_capture env \
    HOME="$machine/home" \
    XDG_CONFIG_HOME="$machine/config" \
    XDG_DATA_HOME="$machine/data" \
    XDG_STATE_HOME="$machine/state" \
    PATH="$mock_bin:/usr/bin:/bin" \
    MOCK_LOG="$mock_log" \
    "$@" \
    "$theme_command" mocha
}

kde_was_applied() {
  grep -q '^lookandfeeltool ' "$mock_log"
}

# --- Fedora --no-kde must never apply KDE identifiers ------------------------

new_machine 'base,dotnet-debug'
run_theme
assert_success
if kde_was_applied; then
  _test_die 'a --no-kde machine must not run KDE apply commands'
fi
assert_contains "$TEST_OUTPUT" 'the KDE capability was not installed'
assert_contains "$TEST_OUTPUT" 'Catppuccin mocha selected.'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: --no-kde never applies KDE theme identifiers\n'

# Even with the KDE assets present from an earlier install, a machine whose
# recorded installation excluded KDE must not apply them.
new_machine 'base,dotnet-debug'
install_kde_assets
run_theme
assert_success
if kde_was_applied; then
  _test_die 'recorded --no-kde must win over leftover KDE assets'
fi
assert_contains "$TEST_OUTPUT" 'the KDE capability was not installed'
printf 'PASS: recorded --no-kde wins over leftover assets\n'

# --- A --kde machine still themes KDE ---------------------------------------

new_machine 'base,dotnet-debug,kde'
install_kde_assets
run_theme
assert_success
kde_was_applied || _test_die 'a --kde machine must apply the KDE theme'
assert_file_contains "$mock_log" 'lookandfeeltool --apply Catppuccin-Mocha-Mauve'
printf 'PASS: a --kde machine applies the KDE theme\n'

# The capability alone is not enough: an identifier whose assets are missing is
# never applied, which is also the migration case for a machine that has the
# hook but never installed the themes.
new_machine 'base,dotnet-debug,kde'
run_theme
assert_success
if kde_was_applied; then
  _test_die 'missing KDE assets must not be applied'
fi
assert_contains "$TEST_OUTPUT" 'Catppuccin KDE assets for mocha are not installed'
printf 'PASS: a selected capability without assets is still skipped\n'

# A machine with no recorded installation at all falls back to the assets.
new_machine
install_kde_assets
run_theme
assert_success
kde_was_applied ||
  _test_die 'with no install state, present assets should still be applied'

new_machine
run_theme
assert_success
if kde_was_applied; then
  _test_die 'with no install state and no assets, nothing may be applied'
fi
printf 'PASS: a machine with no recorded install decides by assets alone\n'

# --- Hook failure isolation -------------------------------------------------

# A failing KDE apply must name itself, must not stop the independent actions
# that follow it, must keep a nonzero result, and must not claim a complete
# theme.
new_machine 'base,dotnet-debug,kde'
install_kde_assets
cat >"$machine/config/dotfiles/theme-hooks.d/zzz-later.sh" <<'EOF'
theme_action later:marker touch "$XDG_STATE_HOME/later-hook-ran"
EOF
run_theme MOCK_KDE_EXIT=9
assert_status 3
assert_contains "$TEST_OUTPUT" 'fedora:kde'
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_not_contains "$TEST_OUTPUT" 'Catppuccin mocha selected.'
# The independent action after the failure still ran.
assert_path_exists "$machine/state/later-hook-ran"
# The shared state is the one thing that must still be current afterwards.
assert_file_line "$machine/config/dotfiles/theme" mocha
assert_file_contains "$machine/config/dotfiles/ghostty.conf" 'catppuccin-mocha.conf'
printf 'PASS: one failing action names itself and spares independent ones\n'

# A Sway session takes over from KDE, and its reload is its own named action.
new_machine 'base,dotnet-debug,kde,sway'
install_kde_assets
run_theme MOCK_SWAY_ACTIVE=true
assert_success
if kde_was_applied; then
  _test_die 'an active Sway session must not trigger KDE theming'
fi
assert_contains "$TEST_OUTPUT" 'a Sway session is running'
assert_file_contains "$mock_log" 'swaymsg reload'
printf 'PASS: an active Sway session replaces KDE theming, not adds to it\n'

# A hook that fails outright is reported and does not stop the other hooks.
new_machine 'base,dotnet-debug'
cat >"$machine/config/dotfiles/theme-hooks.d/aaa-broken.sh" <<'EOF'
printf 'broken hook ran\n'
return 7
EOF
cat >"$machine/config/dotfiles/theme-hooks.d/zzz-later.sh" <<'EOF'
theme_action later:marker touch "$XDG_STATE_HOME/later-hook-ran"
EOF
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'hook:aaa-broken'
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_path_exists "$machine/state/later-hook-ran"
printf 'PASS: a failing hook does not stop the hooks after it\n'

# A hook that calls `exit` must not take the whole command with it.
new_machine 'base,dotnet-debug'
cat >"$machine/config/dotfiles/theme-hooks.d/aaa-exits.sh" <<'EOF'
exit 5
EOF
cat >"$machine/config/dotfiles/theme-hooks.d/zzz-later.sh" <<'EOF'
theme_action later:marker touch "$XDG_STATE_HOME/later-hook-ran"
EOF
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'hook:aaa-exits'
assert_path_exists "$machine/state/later-hook-ran"
printf 'PASS: a hook that exits is contained by its own boundary\n'

# A hook that fails partway must stop at the failure. The two fixtures above
# fail on their last statement, which is also the subshell's own status; a
# failure followed by more code is what `(...) || status=$?` let run on,
# because bash ignores errexit inside a command in an `||` list.
new_machine 'base,dotnet-debug'
cat >"$machine/config/dotfiles/theme-hooks.d/aaa-fails-early.sh" <<'EOF'
false
theme_action hook:mid-hook touch "$XDG_STATE_HOME/mid-hook-marker"
EOF
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'hook "hook:aaa-fails-early" failed (exit 1)'
assert_not_contains "$TEST_OUTPUT" 'selected.'
assert_path_missing "$machine/state/mid-hook-marker"
printf 'PASS: a hook stops at its first failing statement\n'

# The same holds one boundary down, inside a named action.
new_machine 'base,dotnet-debug'
cat >"$machine/config/dotfiles/theme-hooks.d/aaa-action-fails-early.sh" <<'EOF'
fails_early() {
  false
  touch "$XDG_STATE_HOME/mid-action-marker"
}
theme_action hook:fails-early fails_early
EOF
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'action "hook:fails-early" failed (exit 1)'
assert_not_contains "$TEST_OUTPUT" 'selected.'
assert_path_missing "$machine/state/mid-action-marker"
printf 'PASS: an action stops at its first failing statement\n'

# A failure writing the shared state is different: nothing after it is
# meaningful, so the command stops and says so.
new_machine 'base,dotnet-debug'
rm -rf -- "$machine/config/dotfiles"
printf 'not a directory\n' >"$machine/config/dotfiles"
run_theme
assert_status 1
assert_contains "$TEST_OUTPUT" 'shared-state'
assert_not_contains "$TEST_OUTPUT" 'selected.'
printf 'PASS: an unwritable shared state stops the command with status 1\n'

# --- Ghostty guidance -------------------------------------------------------

# Without a hook that owns Ghostty (macOS, for example), the portable command
# must say a restart is required rather than implying a reload applied it.
new_machine
mkdir -p "$machine/config/ghostty"
rm "$machine/config/dotfiles/theme-hooks.d/fedora.sh"
run_theme
assert_success
assert_contains "$TEST_OUTPUT" 'quit and reopen Ghostty'
assert_contains "$TEST_OUTPUT" 'reload does not change an already-set theme'
printf 'PASS: Ghostty guidance is accurate where no hook owns it\n'

# The Fedora hook owns the message. With no Ghostty running it says only that
# new windows pick the theme up.
new_machine 'base,dotnet-debug'
mkdir -p "$machine/config/ghostty"
run_theme
assert_success
assert_contains "$TEST_OUTPUT" 'new windows use catppuccin-mocha'
assert_not_contains "$TEST_OUTPUT" 'quit and reopen Ghostty'

# With Ghostty running it reloads the configuration, but must not claim that
# made the new theme live: Ghostty applies a changed theme only on a restart.
new_machine 'base,dotnet-debug'
mkdir -p "$machine/config/ghostty"
run_theme MOCK_GHOSTTY_RUNNING=true
assert_success
assert_file_contains "$mock_log" 'pkill -USR2 -x ghostty'
assert_contains "$TEST_OUTPUT" 'Restart Ghostty to apply catppuccin-mocha'
assert_contains "$TEST_OUTPUT" 'a reload does not'
for phrase in 'theme applied' 'theme reloaded' 'theme is now active'; do
  assert_not_contains "$TEST_OUTPUT" "$phrase"
done
printf 'PASS: no output claims a live Ghostty theme reload\n'

# A profile without Ghostty (Parrot) must not be told to restart it.
new_machine 'base,vm-guest'
rm "$machine/config/dotfiles/theme-hooks.d/fedora.sh"
run_theme
assert_success
assert_not_contains "$TEST_OUTPUT" 'Ghostty'
printf 'PASS: a profile without Ghostty gets no Ghostty guidance\n'

# --- The Fedora WSL Noctty bridge ------------------------------------------

wsl_hook="$repo_root/platforms/fedora-wsl/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora-wsl.sh"

new_wsl_machine() {
  new_machine 'base,dotnet-debug'
  rm "$machine/config/dotfiles/theme-hooks.d/fedora.sh"
  ln -s "$wsl_hook" "$machine/config/dotfiles/theme-hooks.d/fedora-wsl.sh"
  windows_root="$machine/windows"
  mkdir -p "$windows_root/System32/WindowsPowerShell/v1.0"
}

install_powershell() {
  local exit_code="$1"
  cat >"$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$MOCK_LOG"
exit $exit_code
EOF
  chmod +x "$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe"
}

# Windows owns the terminal on this profile, so no Ghostty guidance is right.
new_wsl_machine
install_powershell 0
mkdir -p "$machine/config/ghostty"
run_theme WINDOWS_SYSTEM_ROOT="$windows_root"
assert_success
assert_file_contains "$mock_log" 'set-theme.ps1'
assert_file_contains "$mock_log" '-Flavor "mocha"'
assert_not_contains "$TEST_OUTPUT" 'Ghostty'
printf 'PASS: the Noctty bridge applies the flavour and owns the terminal message\n'

# A machine whose Windows bootstrap has not run yet is not a failure.
new_wsl_machine
run_theme WINDOWS_SYSTEM_ROOT="$windows_root"
assert_success
assert_contains "$TEST_OUTPUT" 'fedora-wsl:noctty'
assert_contains "$TEST_OUTPUT" 'Windows PowerShell was not found'
assert_contains "$TEST_OUTPUT" 'Catppuccin mocha selected.'
printf 'PASS: an absent Noctty bridge is skipped, not failed\n'

# A PowerShell that actually fails is reported and keeps the result nonzero.
new_wsl_machine
install_powershell 1
run_theme WINDOWS_SYSTEM_ROOT="$windows_root"
assert_status 3
assert_contains "$TEST_OUTPUT" 'fedora-wsl:noctty'
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: a failing Noctty bridge is reported without losing shared state\n'

# --- Parrot owns no desktop theme hooks -------------------------------------

parrot_hooks="$repo_root/platforms/parrot-ctf/stow/theme-hooks"
[[ ! -e "$parrot_hooks" ]] ||
  _test_die 'the Parrot lab profile must not gain workstation desktop theme hooks'
assert_file_not_contains "$repo_root/config/capabilities.tsv" \
  'parrot-ctf	ctf-guest	-	enabled	-	-	apt+upstream	-	-	theme-hooks'
printf 'PASS: the Parrot profile installs no desktop theme hooks\n'

# --- macOS owns no theme hooks either ----------------------------------------

# docs/workflows/theming.md makes the same claim for macOS as for Parrot.
macos_hooks="$repo_root/platforms/macos/stow/theme-hooks"
[[ ! -e "$macos_hooks" ]] ||
  _test_die 'macOS must not gain theme hooks; docs/workflows/theming.md says it installs none'
macos_stow="$(awk -F '\t' '$1 == "base" && $2 == "macos" { print $10 }' \
  "$repo_root/config/capabilities.tsv")"
[[ -n "$macos_stow" ]] || _test_die 'no macOS base capability row with Stow packages'
assert_not_contains ",$macos_stow," ',theme-hooks,'
printf 'PASS: the macOS profile installs no theme hooks\n'

printf 'Theme hook capability and failure-isolation tests passed.\n'
