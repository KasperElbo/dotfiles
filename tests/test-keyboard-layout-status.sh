#!/usr/bin/env bash
set -euo pipefail

# The Waybar keyboard-layout indicator went blank whenever Handy typed through
# wtype: wtype's virtual keyboard reported an unnamed keymap and Waybar's
# native sway/language module showed that. keyboard-layout-status must report
# only physical keyboards with a layout XKB can name, and never print a blank.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

status_command="$repo_root/platforms/fedora/stow/sway/.local/bin/keyboard-layout-status"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"
mock_bin="$root/bin"
fixtures="$root/fixtures"
mkdir -p "$mock_bin" "$fixtures"

test_isolate_path jq
export PATH="$mock_bin:$PATH"

# A slice of xkeyboard-config's rules list, so the codes do not depend on the
# machine running the tests.
cat >"$root/evdev.lst" <<'EOF'
! model
  pc105           Generic 105-key PC

! layout
  us              English (US)
  dk              Danish

! variant
  nodeadkeys      dk: Danish (no dead keys)
EOF
export XKB_RULES_LIST="$root/evdev.lst"

# swaymsg stub: each get_inputs answers with the next fixture in order; a
# subscribe emits one input event per fixture after the first.
cat >"$mock_bin/swaymsg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
fixtures="${SWAYMSG_FIXTURES:?}"
case "$*" in
"-r -t get_inputs")
  counter="$fixtures/.next"
  next="$(cat "$counter" 2>/dev/null || printf '0')"
  cat "$fixtures/inputs.$next.json"
  printf '%s\n' "$((next + 1))" >"$counter"
  ;;
'-r -m -t subscribe ["input"]')
  count="$(find "$fixtures" -name 'inputs.*.json' | wc -l)"
  for ((i = 1; i < count; i++)); do
    printf '{"change":"xkb_layout","input":{"type":"keyboard"}}\n'
  done
  ;;
*)
  printf 'swaymsg stub: unexpected arguments: %s\n' "$*" >&2
  exit 96
  ;;
esac
EOF
chmod +x "$mock_bin/swaymsg"
export SWAYMSG_FIXTURES="$fixtures"

keyboard() {
  # keyboard <identifier> <active layout or null> <layout names JSON array>
  printf '{"identifier":"%s","type":"keyboard","xkb_active_layout_name":%s,"xkb_layout_names":%s}' \
    "$1" "$2" "$3"
}
pointer='{"identifier":"1739:52619:touchpad","type":"pointer"}'
laptop_us="$(keyboard 1:1:AT_Translated_Set_2_keyboard '"English (US)"' '["English (US)","Danish"]')"
laptop_dk="$(keyboard 1:1:AT_Translated_Set_2_keyboard '"Danish"' '["English (US)","Danish"]')"
# What wtype registers: no name XKB knows, and more "layouts" than the laptop
# keyboard so a most-layouts pick would choose it.
wtype_keyboard="$(keyboard 0:0:wlr_virtual_keyboard_v1 '"(unnamed)"' '["(unnamed)","(unnamed)","(unnamed)"]')"
unnamed_keyboard="$(keyboard 0:0:wtype null '[]')"

write_fixtures() {
  rm -f "$fixtures"/inputs.*.json "$fixtures/.next"
  local index=0 fixture
  for fixture in "$@"; do
    printf '%s\n' "$fixture" >"$fixtures/inputs.$index.json"
    index=$((index + 1))
  done
}

# --- one-shot: the virtual keyboard is listed first and has more layouts -----
write_fixtures "[$wtype_keyboard,$unnamed_keyboard,$laptop_dk,$pointer]"
run_capture "$status_command"
assert_success
assert_eq "dk" "$TEST_OUTPUT" "the physical keyboard's layout, not wtype's"

# --- follow: dictation comes and goes, then the layout is switched -----------
write_fixtures \
  "[$laptop_us,$pointer]" \
  "[$wtype_keyboard,$laptop_us,$pointer]" \
  "[$wtype_keyboard,$unnamed_keyboard]" \
  "[$laptop_us]" \
  "[$laptop_dk,$wtype_keyboard]"
run_capture "$status_command" --follow
assert_success
assert_eq $'us\ndk' "$TEST_OUTPUT" \
  "one line per real change, and no blank while only virtual keyboards report"

# --- nothing nameable at startup: a visible placeholder, not an empty slot ---
write_fixtures "[$unnamed_keyboard,$pointer]"
run_capture "$status_command"
assert_success
assert_eq "??" "$TEST_OUTPUT" "unknown layout placeholder"

# --- a variant's description resolves to its layout code ---------------------
write_fixtures "[$(keyboard 1:1:kbd '"Danish (no dead keys)"' '["Danish (no dead keys)"]')]"
run_capture "$status_command"
assert_success
assert_eq "dk" "$TEST_OUTPUT" "variant description"

run_capture "$status_command" --bogus
assert_status 2

printf 'keyboard-layout-status tests passed\n'
