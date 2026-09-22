#!/usr/bin/env bash
# Theme precedence, capability-aware hooks and hook failure isolation (#148).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

# The Fedora hook asks whether there is a graphical session to apply a KDE
# theme to, because the Plasma commands abort without one. This suite is about
# what the hook does on a machine that has one, so the fixture declares a
# session rather than inheriting whatever the runner has -- no CI runner has a
# desktop session, and inheriting would silently turn every KDE assertion below
# into a skip.
export WAYLAND_DISPLAY=wayland-0
unset DISPLAY

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
[[ "$*" != "-USR2 -x ghostty" ]] || exit "${MOCK_GHOSTTY_RELOAD_EXIT:-0}"
EOF
  cat >"$mock_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list-sessions" ]]; then
  [[ "${MOCK_TMUX_SERVER:-false}" == "true" ]] || exit 1
  printf '0: 1 windows\n'
  exit 0
fi
printf 'tmux %s\n' "$*" >>"$MOCK_LOG"
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

# run_theme with a flavour and extra arguments of its own, for the cases that
# are about the flavour rather than about the machine.
run_theme_flavour() {
  local flavour="$1"
  shift
  run_capture env \
    HOME="$machine/home" \
    XDG_CONFIG_HOME="$machine/config" \
    XDG_DATA_HOME="$machine/data" \
    XDG_STATE_HOME="$machine/state" \
    PATH="$mock_bin:/usr/bin:/bin" \
    MOCK_LOG="$mock_log" \
    "$theme_command" "$flavour" "$@"
}

run_theme_with() {
  run_theme_flavour "$@"
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

# A KDE machine with no graphical session running. The commands are all there
# and the assets are installed, so every earlier question answers yes; the only
# thing missing is the session the Plasma commands need, without which they
# abort with SIGABRT rather than returning an error. That has to read as "not
# applicable right now", not as a failure, and the rest of the theme still has
# to apply.
new_machine 'base,dotnet-debug,kde'
install_kde_assets
run_theme WAYLAND_DISPLAY=
assert_success
if kde_was_applied; then
  _test_die 'the Plasma commands ran with no graphical session to apply to'
fi
assert_contains "$TEST_OUTPUT" 'no graphical session is running'
assert_not_contains "$TEST_OUTPUT" 'was applied only partially'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: no graphical session skips the KDE apply instead of failing it\n'

# The control for it: the same machine with a session applies the theme, so the
# skip above is the session's doing and not the fixture's.
new_machine 'base,dotnet-debug,kde'
install_kde_assets
run_theme
assert_success
kde_was_applied ||
  _test_die 'a machine with a graphical session must still apply the KDE theme'
assert_not_contains "$TEST_OUTPUT" 'no graphical session is running'
printf 'PASS: the same machine with a session still applies the KDE theme\n'

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

# A reload that was attempted and failed is not the same answer as no running
# instance, and it used to be reported as one: reload_ghostty returned 1 for
# both, it was called bare in an `if` rather than through theme_action, and so
# a failed reload was recorded neither as applied nor failed nor skipped while
# the command still reported a complete application (GAP-29 of #397).
new_machine 'base,dotnet-debug'
mkdir -p "$machine/config/ghostty"
run_theme MOCK_GHOSTTY_RUNNING=true MOCK_GHOSTTY_RELOAD_EXIT=1
assert_failure
assert_file_contains "$mock_log" 'pkill -USR2 -x ghostty'
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_contains "$TEST_OUTPUT" 'fedora:ghostty'
assert_not_contains "$TEST_OUTPUT" 'no running instance reloaded'
assert_not_contains "$TEST_OUTPUT" 'configuration reload requested'
printf 'PASS: a failed Ghostty reload is recorded, not reported as absent\n'

# And with nothing running it is a named skip rather than an unrecorded effect.
new_machine 'base,dotnet-debug'
mkdir -p "$machine/config/ghostty"
run_theme
assert_success
assert_contains "$TEST_OUTPUT" 'Not applicable on this machine'
assert_contains "$TEST_OUTPUT" 'fedora:ghostty (no running instance to reload)'
printf 'PASS: no Ghostty instance is a named skip\n'

# --- The tmux reload reports what it did (GAP-27 of #397) -------------------
#
# reload_tmux returned 0 both when tmux was absent and when no server was
# running, so `theme_action tmux reload_tmux` recorded `applied` for a reload
# that never happened. The no-server case is the everyday one, and the command
# named tmux in its "Applied:" list on a machine with no tmux at all.

# An isolated PATH, because tmux is in every platform's base package set and
# is on this runner too: a mock that merely exits nonzero still answers
# `command -v`, so the absent case needs a PATH with no tmux on it anywhere.
new_machine 'base,dotnet-debug'
no_tmux_bin="$machine/no-tmux-bin"
mkdir -p "$no_tmux_bin"
for mock in "$mock_bin"/*; do
  [[ "$(basename "$mock")" != tmux ]] || continue
  ln -s "$mock" "$no_tmux_bin/$(basename "$mock")"
done
for required in awk bash basename cat chmod dirname mkdir mktemp mv readlink; do
  ln -s "$(command -v "$required")" "$no_tmux_bin/$required"
done
run_capture env \
  HOME="$machine/home" \
  XDG_CONFIG_HOME="$machine/config" \
  XDG_DATA_HOME="$machine/data" \
  XDG_STATE_HOME="$machine/state" \
  PATH="$no_tmux_bin" \
  MOCK_LOG="$mock_log" \
  "$theme_command" mocha
assert_success
assert_contains "$TEST_OUTPUT" 'tmux (tmux is not installed)'
printf 'PASS: an absent tmux is a named skip, not an applied action\n'

new_machine 'base,dotnet-debug'
run_theme
assert_success
assert_contains "$TEST_OUTPUT" 'tmux (no tmux server is running)'
printf 'PASS: no running tmux server is a named skip\n'

new_machine 'base,dotnet-debug'
run_theme MOCK_TMUX_SERVER=true
assert_success
assert_file_contains "$mock_log" 'tmux source-file'
assert_not_contains "$TEST_OUTPUT" 'tmux (no tmux server is running)'
assert_not_contains "$TEST_OUTPUT" 'tmux (tmux is not installed)'
printf 'PASS: a running tmux server is really reloaded\n'

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

# The middle state the other three cases step over: Windows PowerShell is
# installed, so the hook runs the bridge, but the Windows bootstrap has not
# put set-theme.ps1 in place. PowerShell then exits the status the command
# reserves for that, and the flavour is recorded as skipped rather than as
# applied everywhere.
#
# The Bash side of this contract is what runs here; the PowerShell side is
# asserted below, because this suite runs where there is no PowerShell to run
# the command with.
new_wsl_machine
install_powershell 3
run_theme WINDOWS_SYSTEM_ROOT="$windows_root"
assert_success
assert_contains "$TEST_OUTPUT" 'fedora-wsl:noctty'
assert_contains "$TEST_OUTPUT" 'the Noctty helper is not installed'
assert_contains "$TEST_OUTPUT" 'Catppuccin mocha selected.'
for phrase in 'was applied only partially' 'theme bridge unavailable'; do
  assert_not_contains "$TEST_OUTPUT" "$phrase"
done
printf 'PASS: an uninstalled Noctty helper is skipped, not reported as applied\n'

# Both halves have to agree on the number. The hook names it once and splices
# it into the PowerShell command, so this holds them to the same value rather
# than to two copies of a 3 that could drift apart.
wsl_hook_text="$(cat "$wsl_hook")"
assert_contains "$wsl_hook_text" 'noctty_bridge_absent=3'
assert_contains "$wsl_hook_text" \
  'if (-not (Test-Path -LiteralPath $helper)) { exit '"'"'"$noctty_bridge_absent"'"'"' }'
printf 'PASS: the PowerShell command exits the status the hook reads\n'

# --- Parrot owns no desktop theme hooks -------------------------------------

parrot_hooks="$repo_root/platforms/parrot-ctf/stow/theme-hooks"
[[ ! -e "$parrot_hooks" ]] ||
  _test_die 'the Parrot lab profile must not gain workstation desktop theme hooks'
# Read the Stow column out of the row, the way the macOS check below does.
# The needle this replaces was a tab-delimited line fragment, and theme-hooks
# only ever appears inside the comma-separated Stow column, so planting the
# leak in that column did not make it match.
parrot_stow="$(awk -F '\t' '$1 == "base" && $2 == "parrot-ctf" { print $10 }' \
  "$repo_root/config/capabilities.tsv")"
[[ -n "$parrot_stow" ]] || _test_die 'no parrot-ctf base capability row with Stow packages'
assert_not_contains ",$parrot_stow," ',theme-hooks,'
printf 'PASS: the Parrot profile installs no desktop theme hooks\n'

# --- The macOS hook ---------------------------------------------------------

# macOS now owns a hook, through the same capability and Stow model as the
# others, so it can gain desktop behaviour without the portable command
# growing a `case $(uname)`. It applies nothing yet.
macos_hook="$repo_root/platforms/macos/stow/theme-hooks/.config/dotfiles/theme-hooks.d/macos.sh"
[[ -f "$macos_hook" ]] || _test_die 'the macOS theme hook is missing'
macos_stow="$(awk -F '\t' '$1 == "base" && $2 == "macos" { print $10 }' \
  "$repo_root/config/capabilities.tsv")"
[[ -n "$macos_stow" ]] || _test_die 'no macOS base capability row with Stow packages'
assert_contains ",$macos_stow," ',theme-hooks,'

# What the osascript stub proves, and what it does not. It proves the hook
# selects the asset for the flavour it was given and invokes the interface
# once with that path, and that --preserve-wallpaper invokes it not at all.
# It cannot prove macOS accepted the change: no CI runner here has a desktop
# session, and the real acceptance check is the manual one in
# docs/platforms/macos.md.
new_macos_machine() {
  new_machine 'base'
  rm "$machine/config/dotfiles/theme-hooks.d/fedora.sh"
  ln -s "$macos_hook" "$machine/config/dotfiles/theme-hooks.d/macos.sh"

  mkdir -p "$machine/data/wallpapers"
  for flavour in latte frappe macchiato mocha; do
    printf 'fake webp\n' >"$machine/data/wallpapers/catppuccin-$flavour.webp"
  done

  cat >"$mock_bin/osascript" <<'STUB'
#!/usr/bin/env bash
printf 'osascript %s\n' "$*" >>"$MOCK_LOG"
exit ${MOCK_OSASCRIPT_EXIT:-0}
STUB
  chmod +x "$mock_bin/osascript"
}

# The hook reads $HOME for the stowed asset, and run_theme gives the machine
# its own HOME, so the wallpapers have to be where a stowed package would put
# them: $XDG_DATA_HOME is $machine/data, and $HOME/.local/share is not.
link_stowed_wallpapers() {
  mkdir -p "$machine/home/.local/share"
  ln -sfn "$machine/data/wallpapers" "$machine/home/.local/share/wallpapers"
}

# The intended action is reported as skipped with its reason. A hook that said
# nothing would let the command report a complete application on a Mac whose
# desktop did not change, which is the failure the named-action boundary
# exists to prevent.
# Each flavour applies its own asset, through one call to the interface.
for flavour in latte frappe macchiato mocha; do
  new_macos_machine
  link_stowed_wallpapers
  run_theme_flavour "$flavour"
  assert_success
  assert_contains "$TEST_OUTPUT" "Catppuccin $flavour selected."
  assert_file_line "$machine/config/dotfiles/theme" "$flavour"
  calls="$(grep -c '^osascript ' "$mock_log")"
  [[ "$calls" -eq 1 ]] ||
    _test_die "expected one osascript call for $flavour, got $calls"
  assert_file_contains "$mock_log" \
    "$machine/home/.local/share/wallpapers/catppuccin-$flavour.webp"
  assert_file_contains "$mock_log" 'picture of every desktop'
done
printf 'PASS: each flavour applies its own wallpaper, once\n'

# Rerunning applies the same asset again and changes nothing else. The
# wallpaper call is not conditional on the previous flavour: macOS is the only
# thing that knows what is currently on the desktop.
new_macos_machine
link_stowed_wallpapers
run_theme
assert_success
first="$TEST_OUTPUT"
run_theme
assert_success
[[ "$TEST_OUTPUT" == "$first" ]] ||
  _test_die 'a second theme run through the macOS hook did not repeat itself'
[[ "$(grep -c '^osascript ' "$mock_log")" -eq 2 ]] ||
  _test_die 'the second run did not reapply the same wallpaper'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: rerunning theme through the macOS hook is idempotent\n'

# A wallpaper that will not apply is a named failed action and a partial
# application, not a crash and not a silent success. A Mac that refused the
# Apple Events permission is the case this stands in for.
new_macos_machine
link_stowed_wallpapers
run_theme MOCK_OSASCRIPT_EXIT=1
assert_status 3
assert_contains "$TEST_OUTPUT" 'macos:wallpaper'
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: a wallpaper that will not apply is reported, not swallowed\n'

# A missing asset is refused before the interface is invoked, so a machine
# that never stowed the wallpapers does not get an osascript error instead of
# an answer.
new_macos_machine
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'Wallpaper is missing or unreadable'
[[ ! -s "$mock_log" ]] ||
  _test_die 'osascript was invoked although the asset was missing'
printf 'PASS: a missing wallpaper is refused before the interface is invoked\n'

# --preserve-wallpaper is a different outcome from "not implemented", because
# a run that deliberately left the desktop alone is not the same thing as one
# that could not change it.
new_macos_machine
link_stowed_wallpapers
run_theme_with mocha --preserve-wallpaper
assert_success
assert_contains "$TEST_OUTPUT" '--preserve-wallpaper was requested'
assert_contains "$TEST_OUTPUT" 'Not applicable on this machine'
assert_contains "$TEST_OUTPUT" 'Catppuccin mocha selected.'
# No mutation at all, rather than a snapshot and a restore.
[[ ! -s "$mock_log" ]] ||
  _test_die '--preserve-wallpaper still touched the desktop wallpaper'
# The rest of the theming still happened.
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: --preserve-wallpaper changes no wallpaper and themes everything else\n'

# The hook refuses a flavour it does not know rather than acting on it. The
# portable command validates the flavour first, so this arm is unreachable
# through `theme` itself; sourcing the hook the way the command does is what
# proves the guard is there, and that it returns rather than exiting.
refusal="$(
  DOTFILES_ROOT="$repo_root" bash -c '
    theme_action_skipped() { :; }
    theme_action() { :; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
    flavour="not-a-flavour"
    preserve_wallpaper=false
    run() { source "$1"; }
    run "$1" && printf "returned-zero\n"
    # A deterministic status: the refusal itself is what the assertions read,
    # and an errexit caller must not be killed by the hook doing its job.
    exit 0
  ' _ "$macos_hook" 2>&1
)"
assert_contains "$refusal" 'refusing invalid Catppuccin flavour: not-a-flavour'
assert_not_contains "$refusal" 'returned-zero'
# The hook really loaded its library: a silently failed source would reach the
# same refusal for the wrong reason.
assert_not_contains "$refusal" 'No such file or directory'
printf 'PASS: the macOS hook refuses a flavour it does not know\n'

# And a hook that fails is a partial application rather than a crash: the
# shared state is still written and the command reports what did not apply.
new_macos_machine
# Replacing the link, not writing through it: the installed hook is a symlink
# into this checkout, and `cat >` on it would rewrite the repository's file.
rm "$machine/config/dotfiles/theme-hooks.d/macos.sh"
cat >"$machine/config/dotfiles/theme-hooks.d/macos.sh" <<'HOOK'
theme_action_skipped macos:wallpaper 'stand-in for a failing macOS hook'
false
HOOK
run_theme
assert_status 3
assert_contains "$TEST_OUTPUT" 'was applied only partially'
assert_contains "$TEST_OUTPUT" 'hook:macos'
assert_file_line "$machine/config/dotfiles/theme" mocha
printf 'PASS: a failing macOS hook is a partial application, not a crash\n'

printf 'Theme hook capability and failure-isolation tests passed.\n'
