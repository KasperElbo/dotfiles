#!/usr/bin/env bash
# Guards docs/reference/keybindings.md and docs/cheatsheets/*.tex against silently
# drifting from the tracked Sway, Waybar, and AeroSpace configuration they
# describe (issue #72).
#
# The binding list is not re-typed here. `config/actions.tsv` already records,
# for every action, the pattern that proves it exists in the config and the
# key text the sheet prints; this test reads both out of the registry and
# checks them, so a renamed binding fails in exactly one place instead of
# passing a stale copy in a second one. What stays hand-written below is what
# no registry row can express: that a sheet does *not* claim something, and
# that the reference keeps pointing at each tool's own discovery mechanism.
#
# It is deliberately not a LaTeX compile check, so it does not require a LaTeX
# toolchain to run as part of ./scripts/test.sh.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sway_config="platforms/fedora/stow/sway/.config/sway/config"
waybar_config="$repo_root/platforms/fedora/stow/waybar/.config/waybar/config.jsonc"
aerospace_config="platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml"
kde_layout_doc="$repo_root/docs/platforms/fedora.md"
keybindings_doc="$repo_root/docs/reference/keybindings.md"
cheatsheets_dir="$repo_root/docs/cheatsheets"
sway_tex="$cheatsheets_dir/fedora-sway.tex"
kde_tex="$cheatsheets_dir/fedora-kde.tex"
wsl_tex="$cheatsheets_dir/fedora-wsl.tex"
macos_tex="$cheatsheets_dir/macos.tex"
parrot_tex="$cheatsheets_dir/parrot-ctf.tex"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_in() {
  local file="$1" needle="$2" label="$3"
  grep -Fq "$needle" "$file" || fail "$label: expected to find '$needle' in $file"
}

# --- The registry's own claims about the two window managers ----------------
#
# For every action whose source is the Sway or AeroSpace config: the recorded
# source_pattern must still match that config, and every action the registry
# prints on a sheet must still appear on it. These are the load-bearing
# bindings the cheat sheets are built around, and the registry is where they
# are written down once.
# The patterns are Python regular expressions, so they are matched with the
# same engine scripts/validate-actions.py uses rather than a near-equivalent.
checked="$(
  python3 - "$repo_root" "$sway_config" "$aerospace_config" <<'PYTHON'
import csv, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
wanted = set(sys.argv[2:])
sheets = root / "docs" / "cheatsheets"
problems, checked = [], 0

with (root / "config" / "actions.tsv").open(newline="", encoding="utf-8") as stream:
    for row in csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
        if row["source"] not in wanted or row["print"] != "true":
            continue
        checked += 1
        text = (root / row["source"]).read_text(encoding="utf-8")
        if not re.search(row["source_pattern"], text, re.MULTILINE):
            problems.append(
                f"{row['id']}: config/actions.tsv records "
                f"{row['source_pattern']!r}, which no longer matches {row['source']}"
            )
        for claim in row["sheets"].split(","):
            # A `sheet:prose` claim is checked by scripts/validate-actions.py
            # against the sheet's own `% csprose:` marker: no key text to find.
            if claim.endswith(":prose"):
                continue
            sheet = sheets / f"{claim}.tex"
            if not sheet.is_file():
                problems.append(f"{row['id']}: names a sheet that does not exist: {claim}")
                continue
            if f"\\csrow{{{row['binding']}}}" not in sheet.read_text(encoding="utf-8"):
                problems.append(f"{row['id']}: {claim}.tex no longer prints {row['binding']!r}")

for problem in problems:
    print(problem, file=sys.stderr)
print(0 if problems else checked)
PYTHON
)" || fail "the registry no longer agrees with the Sway/AeroSpace config or the sheets"

((checked >= 20)) ||
  fail "only $checked window-manager bindings were checked; either a drift was found above or the registry columns moved"
printf 'PASS: %d registered Sway/AeroSpace bindings match both the config and the sheet\n' \
  "$checked"

# --- Waybar's keyboard-layout indicator matches what the Sway sheet claims ---
require_in "$waybar_config" '"sway/language"' "Waybar config"
require_in "$waybar_config" '"format": "{short}"' "Waybar config"
require_in "$sway_tex" 'sway/language' "Sway cheat sheet"
require_in "$sway_tex" 'clicked' "Sway cheat sheet"

# --- The Sway sheet's grid note describes the keys the config actually binds --
require_in "$sway_tex" 'Super+Ctrl+H' "Sway cheat sheet"
if grep -Fq 'Ctrl+Left from' "$sway_tex"; then
  fail "Sway cheat sheet: there is no Ctrl+Left binding; the grid keys are Super+Ctrl+H/J/K/L"
fi

# --- The KDE cheat sheet does not claim Plasma's own default as a dotfiles binding ---
require_in "$kde_tex" 'Meta+Alt+K' "Fedora KDE cheat sheet"
require_in "$kde_tex" "Plasma 6's own default" "Fedora KDE cheat sheet"
grep -Eq 'not a dotfiles binding' "$kde_tex" ||
  fail "Fedora KDE cheat sheet: must not imply Meta+Alt+K is a dotfiles binding"

# --- The Fedora WSL cheat sheet omits the layout toggle (Windows owns input) ---
if grep -Fq 'Meta+Alt+K' "$wsl_tex" || grep -Fq 'Super+Alt+K' "$wsl_tex"; then
  fail "Fedora WSL cheat sheet: must not include the KDE/Sway keyboard-layout shortcut"
fi
require_in "$wsl_tex" 'wsl-open' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'wsl-copy' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'wsl-paste' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'enabled=true' "Fedora WSL cheat sheet"
require_in "$wsl_tex" 'appendWindowsPath=false' "Fedora WSL cheat sheet"

# --- The shared terminal block leaves its platform-dependent line to the sheet --
require_in "$cheatsheets_dir/common-workflow.tex" '\cstermlegend' "shared workflow block"
require_in "$cheatsheets_dir/common-workflow.tex" '\cstermdefaults' "shared workflow block"
if grep -Fq 'ghostty +list-keybinds' "$cheatsheets_dir/common-workflow.tex"; then
  fail "common-workflow.tex: the Ghostty discovery command belongs to the sheets that have it"
fi
for tex in "$kde_tex" "$sway_tex" "$macos_tex" "$wsl_tex"; do
  require_in "$tex" '\renewcommand{\cstermlegend}' "$(basename "$tex")"
done

# --- Each sheet prints its own terminal's defaults, never another platform's --
#
# The registry proves each printed key is claimed; what it cannot say is that
# the three default sets stay apart. Ghostty splits right with Ctrl+Shift+O on
# Linux and Cmd+D on macOS, and Noctty on Windows documents Ctrl+Shift+\ --- so
# a sheet carrying the wrong one of those three is carrying the wrong table.
ghostty_linux_keys="$cheatsheets_dir/ghostty-linux-keys.tex"
[[ -f "$ghostty_linux_keys" ]] ||
  fail "missing tracked file: $ghostty_linux_keys"
require_in "$ghostty_linux_keys" 'Ctrl+Shift+O / E' "shared Ghostty/Linux key table"
for tex in "$kde_tex" "$sway_tex"; do
  require_in "$tex" '\input{ghostty-linux-keys}' "$(basename "$tex")"
  if grep -Fq 'Cmd+D' "$tex"; then
    fail "$(basename "$tex"): prints Ghostty's macOS split key on a Linux sheet"
  fi
done
require_in "$macos_tex" 'Cmd+D / Cmd+Shift+D' "macOS cheat sheet"
require_in "$macos_tex" 'Cmd+C / Cmd+V' "macOS cheat sheet"
if grep -Fq 'Ctrl+Shift+O' "$macos_tex"; then
  fail "macOS cheat sheet: prints Ghostty's Linux split key"
fi
require_in "$wsl_tex" 'noctty +list-keybinds' "Fedora WSL cheat sheet"
grep -Fq 'Ctrl+Shift+\textbackslash' "$wsl_tex" ||
  fail "Fedora WSL cheat sheet: must print Noctty's own Ctrl+Shift+\\ split key"
if grep -Fq 'ghostty +list-keybinds' "$wsl_tex"; then
  fail "Fedora WSL cheat sheet: names a ghostty command its runtime does not have"
fi

# --- Herdr is printed as the optional profile it is ------------------------
#
# Every other tool on the sheets is installed by a default ./install.sh; Herdr
# is not, so a sheet that prints its keys has to say which flag installs it.
require_in "$cheatsheets_dir/common-workflow.tex" 'Herdr' "shared workflow block"
require_in "$cheatsheets_dir/common-workflow.tex" './install.sh --ai' "shared workflow block"

# --- The Fedora guide documents the layout switch the KDE sheet prints ---
require_in "$kde_layout_doc" 'Meta+Alt+K' "docs/platforms/fedora.md"

# --- The reduced Parrot sheet documents only guest/profile behavior ---
for phrase in 'hex-encode' 'hex-decode' 'rot13' 'x-copy' 'NOMATCH' \
  'system Python' 'pinned Neovim'; do
  require_in "$parrot_tex" "$phrase" "Parrot CTF cheat sheet"
done
if grep -Eq 'Angular|TeX|\.NET' "$parrot_tex" &&
  ! grep -Fq 'excludes .NET, Angular, TeX' "$parrot_tex"; then
  fail "Parrot CTF cheat sheet advertises workstation editor integrations"
fi

# --- ...and the shared shell the guest genuinely stows -----------------------
for phrase in 'theme <f>' 'untar A.tar.gz' 'shell-integrations' 'Ctrl+T' 'Prefix ?'; do
  require_in "$parrot_tex" "$phrase" "Parrot CTF cheat sheet"
done

# --- Discovery mechanisms stay prominent rather than static tables drifting ---
for phrase in \
  'ghostty +list-keybinds --default' \
  'noctty +list-keybinds' \
  'WhichKey' \
  'Lazygit' \
  '<prefix> ?' \
  'Ctrl+B ?' \
  'System Settings'; do
  grep -Fq "$phrase" "$keybindings_doc" ||
    fail "docs/reference/keybindings.md: expected discovery reference '$phrase'"
done

# --- Every cheat sheet input file referenced actually exists ---
for f in "$sway_tex" "$kde_tex" "$wsl_tex" "$macos_tex" "$parrot_tex" \
  "$cheatsheets_dir/common-workflow.tex" "$cheatsheets_dir/ghostty-linux-keys.tex" \
  "$cheatsheets_dir/cheatsheet.sty" "$cheatsheets_dir/generate.sh"; do
  [[ -f "$f" ]] || fail "missing tracked file: $f"
done
[[ -x "$cheatsheets_dir/generate.sh" ]] ||
  fail "$cheatsheets_dir/generate.sh must be executable"

printf 'Cheat sheet / keybinding documentation accuracy checks passed.\n'
