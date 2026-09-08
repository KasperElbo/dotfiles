#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
macos_root="$repo_root/platforms/macos"
config="$macos_root/stow/aerospace/.config/aerospace/aerospace.toml"
grid="$macos_root/stow/aerospace/.local/bin/aerospace-workspace-grid"
brewfile="$macos_root/Brewfile"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

assert_contains() {
  local value="$1"
  local expected="$2"
  [[ "$value" == *"$expected"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$expected" "$value" >&2
    exit 1
  }
}

dry_run="$($repo_root/install.sh --platform macos --dry-run --ocaml --containers --workflows)"
assert_contains "$dry_run" 'Apple Silicon macOS installation plan'
assert_contains "$dry_run" 'AeroSpace (Sway-compatible nine-workspace profile)'
assert_contains "$dry_run" 'Homebrew at /opt/homebrew'
assert_contains "$dry_run" 'OCaml profile:      true'
assert_contains "$dry_run" 'Containers profile: true'
assert_contains "$dry_run" 'Development tests:  true'
assert_contains "$dry_run" 'Podman machine'
assert_contains "$dry_run" 'AI tooling profile: unavailable until repository issue #16 lands'
assert_contains "$dry_run" 'No changes were made.'

no_defaults="$($repo_root/install.sh --platform macos --dry-run --no-defaults)"
assert_contains "$no_defaults" 'macOS defaults:     false'
if [[ "$no_defaults" == *'Apply reversible Dock'* ]]; then
  printf 'No-defaults dry run still planned preference mutation.\n' >&2
  exit 1
fi

# Homebrew owns machine tools/apps; mise retains portable runtimes and Lazygit.
for package in bash bat coreutils eza fd fzf gh git git-delta mise neovim ripgrep shellcheck sqlite starship stow tmux zoxide; do
  grep -Eq "^brew \"$package\"$" "$brewfile"
done
grep -Fq 'cask "ghostty"' "$brewfile"
grep -Fq 'cask "nikitabobko/tap/aerospace"' "$brewfile"
grep -Fq 'Intel Homebrew exists at /usr/local/bin/brew' \
  "$macos_root/scripts/install-system.sh"
for package in lazygit node python dotnet uv; do
  if grep -Eq "^brew \"$package\"$" "$brewfile"; then
    printf 'Portable mise-owned tool is duplicated in Brewfile: %s\n' "$package" >&2
    exit 1
  fi
done

# The selected manager is exclusive and preserves the Sway mental model.
if rg -l -i 'yabai|skhd' "$macos_root" --glob '!docs/**' | grep -q .; then
  printf 'macOS implementation contains an unselected window manager.\n' >&2
  exit 1
fi
grep -Fq 'config-version = 2' "$config"
grep -Fq 'start-at-login = true' "$config"
grep -Fq 'auto-reload-config = true' "$config"
grep -Fq "persistent-workspaces = ['1', '2', '3', '4', '5', '6', '7', '8', '9']" "$config"
python3 - "$config" <<'PY'
import pathlib
import sys
import tomllib

with pathlib.Path(sys.argv[1]).open("rb") as stream:
    config = tomllib.load(stream)
assert config["config-version"] == 2
assert len(config["persistent-workspaces"]) == 9
assert len(config["mode"]["main"]["binding"]) >= 40
PY
for binding in \
  "ctrl-alt-enter = 'exec-and-forget open -na Ghostty'" \
  "ctrl-alt-h = 'focus --boundaries all-monitors-outer-frame left'" \
  "ctrl-alt-shift-l = 'move --boundaries all-monitors-outer-frame right'" \
  "ctrl-alt-1 = 'workspace 1'" \
  "ctrl-alt-shift-9 = 'move-node-to-workspace 9'" \
  "ctrl-alt-cmd-h = 'exec-and-forget ~/.local/bin/aerospace-workspace-grid left'" \
  "ctrl-alt-shift-space = 'layout floating tiling'" \
  "ctrl-alt-f = 'fullscreen'" \
  "ctrl-alt-r = 'mode resize'" \
  "ctrl-alt-shift-tab = 'move-node-to-monitor --wrap-around --focus-follows-window next'"; do
  grep -Fq "$binding" "$config"
done

# Exercise wrapped workspace-grid navigation against a mock CLI.
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"
command_log="$test_root/aerospace.log"
cat >"$mock_bin/aerospace" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == list-workspaces && "$2" == --focused ]]; then
  printf '%s\n' "$MOCK_WORKSPACE"
elif [[ "$1" == workspace ]]; then
  printf '%s\n' "$2" >>"$COMMAND_LOG"
else
  exit 2
fi
EOF
chmod +x "$mock_bin/aerospace"

check_grid() {
  local current="$1"
  local direction="$2"
  local expected="$3"
  : >"$command_log"
  MOCK_WORKSPACE="$current" COMMAND_LOG="$command_log" PATH="$mock_bin:$PATH" \
    "$grid" "$direction"
  [[ "$(<"$command_log")" == "$expected" ]] || {
    printf 'Grid %s from %s did not reach %s.\n' "$direction" "$current" "$expected" >&2
    exit 1
  }
}

check_grid 1 left 3
check_grid 3 right 1
check_grid 2 up 8
check_grid 8 down 2
check_grid 5 right 6

# Defaults are inspectable and reversible without changing this Linux runner.
apply_plan="$($macos_root/scripts/apply-defaults.sh --dry-run)"
restore_plan="$($macos_root/scripts/apply-defaults.sh --restore --dry-run)"
assert_contains "$apply_plan" 'defaults write com.apple.dock autohide -bool true'
assert_contains "$apply_plan" 'defaults write com.apple.dock mru-spaces -bool false'
assert_contains "$restore_plan" 'defaults delete com.apple.dock autohide'
assert_contains "$restore_plan" 'defaults delete NSGlobalDomain KeyRepeat'

grep -Fq 'SIP and Gatekeeper remain enabled' "$repo_root/docs/macos.md"
grep -Fq 'Command+Space' "$repo_root/docs/macos.md"
grep -Fq 'Displays have separate Spaces' "$repo_root/docs/macos.md"
grep -Fq 'platforms/macos/scripts/apply-defaults.sh --restore' "$repo_root/docs/macos.md"

printf 'macOS profile configuration checks passed.\n'
