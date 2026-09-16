#!/usr/bin/env bash
# What each platform's Ghostty actually resolves, and that the macOS-only
# Option/Alt mapping stays macOS-only (#257).
#
# Ghostty reads one entry point and follows its `config-file` directives, so no
# single tracked file states what a terminal ends up with. Every assertion here
# resolves that include chain from a really stowed HOME -- the same way Ghostty
# does, last assignment winning -- and asserts the effective setting, rather
# than reading a key out of the file a platform happens to own today.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git python3 stow

# resolve <entry-point> <key>: the effective value Ghostty would hold for that
# key after following the entry point's includes, empty if it is never set.
resolve() {
  python3 - "$1" "$2" <<'PYTHON'
import pathlib, sys

entry, wanted = pathlib.Path(sys.argv[1]), sys.argv[2]
settings: dict[str, str] = {}


def load(path: pathlib.Path, seen: set[pathlib.Path]) -> None:
    # Ghostty ignores a repeated include rather than looping forever.
    resolved = path.resolve()
    if resolved in seen:
        return
    seen.add(resolved)
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key != "config-file":
            # A later assignment wins, which is what makes the machine-local
            # theme override an override.
            settings[key] = value
            continue
        optional = value.startswith("?")
        target = pathlib.Path(value[1:] if optional else value)
        if not target.is_absolute():
            target = path.parent / target
        if not target.exists():
            if optional:
                continue
            raise SystemExit(f"missing required config-file: {target}")
        load(target, seen)


load(entry, set())
print(settings.get(wanted, ""))
PYTHON
}

# stow_home <script>: a fresh HOME with that entry point's packages really
# stowed into it, left in STOW_HOME. Assigning rather than printing keeps
# test_new_root's bookkeeping in this shell, so the exit trap still removes the
# root instead of leaking it from a command substitution's subshell.
STOW_HOME=""
stow_home() {
  local script="$1"
  test_new_root
  STOW_HOME="$TEST_ROOT/home"
  mkdir -p "$STOW_HOME"
  HOME="$STOW_HOME" \
    XDG_CONFIG_HOME="$STOW_HOME/.config" \
    XDG_DATA_HOME="$STOW_HOME/.local/share" \
    DOTFILES_ROOT="$repo_root" \
    "$script" >/dev/null
}

# --- macOS resolves Left Option as Alt --------------------------------------
#
# fzf's Alt-C directory picker is a shared binding this repository expects to
# work everywhere. On a Mac the physical key is Option, and Ghostty only sends
# it as Meta when told to, so without this setting Option+C types a character
# on a Danish layout instead of reaching the widget.

stow_home "$repo_root/platforms/macos/scripts/stow.sh"
macos_home="$STOW_HOME"
macos_config="$macos_home/.config/ghostty/config"

assert_path_exists "$macos_config"
# Right Option stays a normal macOS modifier: `left`, not `true`, is what
# keeps Danish symbol entry working on the other key.
assert_eq left "$(resolve "$macos_config" macos-option-as-alt)" \
  'macOS Ghostty must send Left Option as Alt'
printf 'PASS: macOS Ghostty resolves Left Option as Alt, Right Option untouched\n'

# The setting is owned by the macOS platform layer, not the portable package.
macos_include="$macos_home/.config/ghostty/macos.conf"
assert_path_exists "$macos_include"
assert_eq "$repo_root/platforms/macos/stow/ghostty-macos/.config/ghostty/macos.conf" \
  "$(readlink -f "$macos_include")" \
  'the macOS Ghostty include must come from the macOS Stow package'
printf 'PASS: the macOS Ghostty include is owned by the macOS Stow package\n'

# --- The setting does not leak to any other platform ------------------------

stow_home "$repo_root/platforms/fedora/scripts/stow.sh"
fedora_home="$STOW_HOME"
fedora_config="$fedora_home/.config/ghostty/config"

assert_path_exists "$fedora_config"
assert_eq "" "$(resolve "$fedora_config" macos-option-as-alt)" \
  'Fedora Ghostty must not carry a macOS-only setting'
assert_path_missing "$fedora_home/.config/ghostty/macos.conf"
printf 'PASS: Fedora Ghostty resolves no macOS-only setting\n'

# Noctty on Windows is handed shared.conf directly (platforms/windows/install.ps1),
# so a macOS key added there would reach a terminal that cannot parse it.
shared="$repo_root/ghostty/.config/ghostty/shared.conf"
assert_eq "" "$(resolve "$shared" macos-option-as-alt)" \
  'the configuration Noctty loads must stay portable'
printf 'PASS: the shared Noctty configuration stays free of macOS settings\n'

# --- The include chain still behaves the way the rest of the repository relies on

# The machine-local theme override is written after the shared theme and must
# still win on macOS, where it is now no longer the only extra include.
theme_state="$macos_home/.config/dotfiles"
mkdir -p "$theme_state"
printf 'theme = catppuccin-latte.conf\n' >"$theme_state/ghostty.conf"

assert_eq 'catppuccin-latte.conf' "$(resolve "$macos_config" theme)" \
  'the machine-local theme override must still win on macOS'
assert_eq left "$(resolve "$macos_config" macos-option-as-alt)" \
  'a theme switch must not disturb the Option mapping'
printf 'PASS: the machine-local theme override still wins on macOS\n'

printf 'All Ghostty configuration tests passed.\n'
