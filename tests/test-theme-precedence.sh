#!/usr/bin/env bash
# Where a run's Catppuccin flavour comes from, and that a rerun keeps it (#148).
#
# The installers are exercised through --dry-run so nothing is installed: the
# resolution and its reported provenance are what this suite is about. The
# --rerun path is included because the remembered flavour must survive it
# through the structured selection recorded by #210/#211, not through any
# theme-specific store of its own.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap

platforms=(fedora fedora-wsl macos parrot-ctf)

new_machine() {
  test_new_root
  machine="$TEST_ROOT"
  mkdir -p "$machine/config/dotfiles" "$machine/state/dotfiles"
}

set_existing_theme() {
  printf '%s\n' "$1" >"$machine/config/dotfiles/theme"
}

# Record a successful install whose remembered selection carries a flavour.
record_remembered() {
  local platform="$1" flavour="$2" selection option value
  selection=""
  while IFS= read -r option; do
    if [[ "$option" == theme ]]; then
      value="$flavour"
    else
      value="$(awk -F '\t' -v p="$platform" -v o="$option" \
        'NR > 1 && $1 == p && $2 == o { print $6; exit }' \
        "$repo_root/config/install-options.tsv")"
      # A manifest default of "auto" is the installer's own detection or
      # prompt, never a recorded value. A real install records what it
      # resolved to, and on an unattended machine that is false.
      [[ "$value" != auto ]] || value=false
    fi
    selection+="${selection:+,}$option:$value"
  done < <(awk -F '\t' -v p="$platform" 'NR > 1 && $1 == p { print $2 }' \
    "$repo_root/config/install-options.tsv")

  cat >"$machine/state/dotfiles/install.conf" <<EOF
schema_version=2
profile=install
status=installed
platform=$platform
requested_capabilities=base
observed_capabilities=base
external_assurance=not-recorded
repository=local-checkout
revision=testrevision
provenance=capability-manifest@testrevision
selection=$selection
last_successful_selection=$selection
last_successful_platform=$platform
last_successful_at=2026-01-01T00:00:00Z
selection_schema=1
EOF
}

dry_run() {
  local platform="$1"
  shift
  run_capture env \
    HOME="$machine/home" \
    XDG_CONFIG_HOME="$machine/config" \
    XDG_DATA_HOME="$machine/data" \
    XDG_STATE_HOME="$machine/state" \
    bash "$repo_root/platforms/$platform/install.sh" --dry-run "$@"
}

# The dry-run label differs per platform; both forms carry flavour and source.
assert_resolved() {
  local flavour="$1" source="$2"
  assert_success
  if [[ "$TEST_OUTPUT" != *"$flavour"*"$source"* ]]; then
    _test_die "expected flavour '$flavour' from source '$source'; output:\n$TEST_OUTPUT"
  fi
}

# --- First install uses the default ----------------------------------------

for platform in "${platforms[@]}"; do
  new_machine
  dry_run "$platform"
  assert_resolved macchiato default
done
printf 'PASS: a first install resolves the default flavour\n'

# --- An explicit --theme always wins ----------------------------------------

for platform in "${platforms[@]}"; do
  new_machine
  set_existing_theme latte
  record_remembered "$platform" frappe
  dry_run "$platform" --theme mocha
  assert_resolved mocha explicit
done
printf 'PASS: an explicit --theme wins over every remembered value\n'

# --- A plain rerun keeps the machine's existing flavour ---------------------

for platform in "${platforms[@]}"; do
  new_machine
  set_existing_theme latte
  dry_run "$platform"
  assert_resolved latte existing
  assert_not_contains "$TEST_OUTPUT" 'macchiato'
done
printf 'PASS: a plain rerun keeps the existing flavour instead of the default\n'

# --- Without a theme file, the remembered selection is used -----------------

for platform in "${platforms[@]}"; do
  new_machine
  record_remembered "$platform" frappe
  dry_run "$platform"
  assert_resolved frappe remembered
done
printf 'PASS: a missing theme file falls back to the remembered selection\n'

# A record belonging to another platform is not adopted.
new_machine
record_remembered fedora frappe
dry_run macos
assert_resolved macchiato default
printf 'PASS: a remembered selection is not borrowed across platforms\n'

# A corrupt or unknown theme file is ignored rather than propagated.
new_machine
printf 'not-a-flavour\n' >"$machine/config/dotfiles/theme"
record_remembered fedora frappe
dry_run fedora
assert_resolved frappe remembered

new_machine
printf 'not-a-flavour\n' >"$machine/config/dotfiles/theme"
dry_run fedora
assert_resolved macchiato default
printf 'PASS: an invalid theme state file is ignored, not propagated\n'

# An unreadable or foreign-schema record is a quiet fallback, not a failure.
new_machine
record_remembered fedora frappe
printf 'this is not lifecycle state\n' >"$machine/state/dotfiles/install.conf"
dry_run fedora
assert_resolved macchiato default

new_machine
record_remembered fedora frappe
sed -i 's/^selection_schema=1$/selection_schema=99/' \
  "$machine/state/dotfiles/install.conf"
dry_run fedora
assert_resolved macchiato default
printf 'PASS: an unreadable or future-schema record falls through quietly\n'

# --- --rerun replays the remembered flavour ---------------------------------

for platform in "${platforms[@]}"; do
  new_machine
  record_remembered "$platform" latte
  run_capture env \
    HOME="$machine/home" \
    XDG_CONFIG_HOME="$machine/config" \
    XDG_DATA_HOME="$machine/data" \
    XDG_STATE_HOME="$machine/state" \
    bash "$repo_root/install.sh" --rerun --dry-run
  assert_success
  # Reconstructed through the shared selection library, as an explicit option.
  assert_contains "$TEST_OUTPUT" '--theme latte'
  assert_resolved latte explicit
  assert_not_contains "$TEST_OUTPUT" '--theme macchiato'
done
printf 'PASS: --rerun replays the remembered flavour through the selection record\n'

# A theme the user changed afterwards does not rewrite the remembered record:
# --rerun reapplies what the last successful install recorded.
new_machine
record_remembered fedora latte
set_existing_theme mocha
run_capture env \
  HOME="$machine/home" \
  XDG_CONFIG_HOME="$machine/config" \
  XDG_DATA_HOME="$machine/data" \
  XDG_STATE_HOME="$machine/state" \
  bash "$repo_root/install.sh" --rerun --dry-run
assert_success
assert_contains "$TEST_OUTPUT" '--theme latte'
printf 'PASS: --rerun uses the recorded selection, not the current theme file\n'

# --- The theme is part of the remembered configuration ----------------------

for platform in "${platforms[@]}"; do
  awk -F '\t' -v p="$platform" \
    'NR > 1 && $1 == p && $2 == "theme" { found = 1 } END { exit !found }' \
    "$repo_root/config/install-options.tsv" ||
    _test_die "platform $platform does not declare theme as a persistent option"
done

# A dry run must not record anything: the remembered configuration belongs to
# a successful install only.
new_machine
record_remembered fedora latte
before="$(cat "$machine/state/dotfiles/install.conf")"
dry_run fedora --theme mocha
assert_resolved mocha explicit
assert_eq "$before" "$(cat "$machine/state/dotfiles/install.conf")" \
  'a dry run must not touch the remembered configuration'
assert_path_missing "$machine/config/dotfiles/theme"
printf 'PASS: a dry run changes no theme or lifecycle state\n'

# Transient execution controls are never theme state.
assert_file_not_contains "$repo_root/config/install-options.tsv" 'dry-run'
assert_file_not_contains "$repo_root/config/install-options.tsv" 'non-interactive'
printf 'PASS: transient controls are not part of the remembered selection\n'

# --- A failed run never becomes the remembered flavour ----------------------
#
# The last-known-good invariant itself is owned by tests/test-install-rerun.sh;
# this asserts the consequence that matters here, namely that a run which
# failed at the theme step does not make its flavour the one a later rerun
# resolves.
new_machine
record_remembered fedora latte
failing_selection="$(
  sed -n 's/^last_successful_selection=//p' "$machine/state/dotfiles/install.conf" |
    sed 's/^theme:latte/theme:mocha/'
)"
env   HOME="$machine/home"   XDG_CONFIG_HOME="$machine/config"   XDG_DATA_HOME="$machine/data"   XDG_STATE_HOME="$machine/state"   bash -c "
    set -euo pipefail
    source '$repo_root/common/lib/common.sh'
    source '$repo_root/common/lib/install-lifecycle.sh'
    install_lifecycle_begin fedora base './install.sh --platform fedora' \
      '$failing_selection'
    install_lifecycle_failed theme 'system,stow' 'theme,verify'
  "

assert_eq failed   "$(sed -n 's/^status=//p' "$machine/state/dotfiles/install.conf")"   'the failed run should be recorded as failed'
assert_file_contains "$machine/state/dotfiles/install.conf"   'last_successful_selection=theme:latte'
dry_run fedora
assert_resolved latte remembered
printf 'PASS: a run that failed at the theme step is not remembered\n'

# And a successful explicit change does become the new remembered flavour.
new_machine
record_remembered fedora latte
record_remembered fedora mocha
dry_run fedora
assert_resolved mocha remembered
printf 'PASS: a successful explicit change becomes the remembered flavour\n'

# --- Provenance is reported -------------------------------------------------

new_machine
set_existing_theme latte
dry_run fedora
assert_contains "$TEST_OUTPUT" 'existing choice on this machine'

new_machine
record_remembered fedora frappe
dry_run fedora
assert_contains "$TEST_OUTPUT" 'remembered configuration of the last successful install'

new_machine
dry_run fedora
assert_contains "$TEST_OUTPUT" 'first-install default'

new_machine
dry_run fedora --theme mocha
assert_contains "$TEST_OUTPUT" 'explicit --theme on this run'
printf 'PASS: dry-run output explains where the flavour came from\n'

# --- One list of flavours ---------------------------------------------------
#
# The supported flavours are the theme option's values in the option manifest
# (#242). The runtime checks read them rather than repeating them, so a value
# added to the manifest is accepted and a value it does not list is not.

new_machine
flavour_manifest="$machine/install-options.tsv"
awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "theme" { $7 = $7 "|oled" } { print }' \
  "$repo_root/config/install-options.tsv" >"$flavour_manifest"
flavour_check='source "$1/common/lib/common.sh"; source "$1/common/lib/theme-selection.sh"
  theme_flavour_is_valid "$2" "$3"'
run_capture env "INSTALL_OPTION_MANIFEST=$flavour_manifest" \
  bash -c "$flavour_check" _ "$repo_root" fedora oled
assert_success
run_capture env "INSTALL_OPTION_MANIFEST=$flavour_manifest" \
  bash -c "$flavour_check" _ "$repo_root" parrot-ctf espresso
assert_failure
run_capture bash -c "$flavour_check" _ "$repo_root" macos oled
assert_failure
printf 'PASS: the valid flavours are the option manifest theme values\n'

run_capture env "HOME=$machine/home" "XDG_CONFIG_HOME=$machine/config" \
  "$repo_root/common/setup-local.sh" fedora oled
assert_failure
assert_contains "$TEST_OUTPUT" 'Invalid Catppuccin flavour: oled'
run_capture env "HOME=$machine/home" "XDG_CONFIG_HOME=$machine/config" \
  "$repo_root/common/setup-local.sh" nowhere macchiato
assert_failure
assert_contains "$TEST_OUTPUT" 'No theme option is declared for platform: nowhere'
assert_path_missing "$machine/config/dotfiles/theme"
printf 'PASS: local setup checks the flavour against the same manifest\n'

# --- The theme plan step applies the theme or fails (GAP-38) ----------------
#
# `theme` is deployed by the shared `bin` Stow package, two plan positions
# before the theme step. Each installer's apply_theme used to be
# `[[ ! -x "$HOME/.local/bin/theme" ]] || ...`, so a run whose Stow step
# deployed nothing still printed "[theme] completed" having applied nothing.
# One helper now decides, and it fails instead.

new_machine
apply_home="$machine/apply-home"
mkdir -p "$apply_home/.local/bin"
apply_stowed='source "$1/common/lib/common.sh"
  source "$1/common/lib/theme-selection.sh"
  theme_apply_stowed "$2"'

run_capture env "HOME=$apply_home" bash -c "$apply_stowed" _ "$repo_root" mocha
assert_failure
assert_contains "$TEST_OUTPUT" 'The theme command is not installed at'

printf '#!/usr/bin/env bash\nprintf "applied %%s\\n" "$1"\n' \
  >"$apply_home/.local/bin/theme"
chmod +x "$apply_home/.local/bin/theme"
run_capture env "HOME=$apply_home" bash -c "$apply_stowed" _ "$repo_root" mocha
assert_success
assert_contains "$TEST_OUTPUT" 'applied mocha'

printf '#!/usr/bin/env bash\nexit 4\n' >"$apply_home/.local/bin/theme"
run_capture env "HOME=$apply_home" bash -c "$apply_stowed" _ "$repo_root" mocha
assert_status 4
printf 'PASS: the theme apply helper fails when the stowed command is missing\n'

# The four installers each carried their own copy of the lenient guard, so the
# helper only holds while all four still route through it.
for platform in "${platforms[@]}"; do
  assert_file_line "$repo_root/platforms/$platform/install.sh" \
    'apply_theme() { theme_apply_stowed "$theme"; }'
done
printf 'PASS: every installer applies the theme through the shared helper\n'

printf 'Theme precedence and rerun-preservation tests passed.\n'
