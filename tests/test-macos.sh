#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/source-code.sh
source "$repo_root/tests/lib/source-code.sh"
macos_root="$repo_root/platforms/macos"
# shellcheck source=../platforms/macos/lib/macos.sh
source "$macos_root/lib/macos.sh"
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

# The three searches below are negative assertions: they pass when ripgrep
# prints nothing. `|| true` made "nothing" and "could not search" the same
# answer, so with rg missing its exit 127 was swallowed and every one of them
# passed on a tree that violated them. ripgrep exits 1 when it matched
# nothing and 2 or more when it failed; only the first is an answer.
command -v rg >/dev/null 2>&1 || {
  printf 'ripgrep is required: without it the searches below report nothing and pass.\n' >&2
  exit 1
}

rg_matches() {
  local output status=0
  # The status is captured on the failing branch rather than read afterwards:
  # an `if` whose condition is false and which has no `else` returns 0.
  output="$(rg "$@")" || status=$?
  ((status <= 1)) || {
    printf 'ripgrep could not search (exit %d): rg %s\n' "$status" "$*" >&2
    exit 1
  }
  printf '%s\n' "$output"
}

# Only GitHub-hosted runners may treat an unobservable SIP state as an
# evidence-boundary outcome. Self-hosted Actions machines are real hosts and
# must retain the normal invariant check.
GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted macos_is_github_hosted_runner
if GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=self-hosted macos_is_github_hosted_runner; then
  printf 'A self-hosted GitHub Actions runner was mistaken for a hosted runner.\n' >&2
  exit 1
fi
if GITHUB_ACTIONS=false RUNNER_ENVIRONMENT=github-hosted macos_is_github_hosted_runner; then
  printf 'A non-Actions process was mistaken for a GitHub-hosted runner.\n' >&2
  exit 1
fi

dry_run="$("$repo_root"/install.sh --platform macos --dry-run --ocaml --containers --dev-workflows)"
assert_contains "$dry_run" 'Apple Silicon macOS installation plan'
assert_contains "$dry_run" 'AeroSpace (Sway-compatible nine-workspace profile)'
assert_contains "$dry_run" 'Homebrew at /opt/homebrew'
assert_contains "$dry_run" 'OCaml profile:       true'
assert_contains "$dry_run" 'Podman machine profile: true'
assert_contains "$dry_run" 'Development workflow smoke tests: true'
assert_contains "$dry_run" 'Podman machine'
assert_contains "$dry_run" 'AI-assisted development profile (Claude Code and Herdr): false'
assert_contains "$dry_run" 'No changes were made.'

# The containers profile is the one macOS capability no CI job installs. A
# hosted macOS runner is itself a virtual machine, so vfkit has no nested
# virtualisation and `podman machine start` exits 1 there whatever this
# repository does. That has to be a recorded decision with its reason and a
# manual check standing in for it, not a flag quietly dropped from the
# workflow, so the registry says so and names where the check lives.
containers_scope="$(awk -F '\t' '$1 == "containers" && $2 == "macos" { print $18 }' \
  "$repo_root/config/capabilities.tsv")"
[[ -n "$containers_scope" ]] ||
  _test_die 'config/capabilities.tsv has no macos row for the containers capability'
case "$containers_scope" in
excluded:*) ;;
*) _test_die "the macos containers row must record its CI exclusion, got: $containers_scope" ;;
esac
assert_contains "$containers_scope" 'docs/platforms/macos.md#optional-containers'

no_defaults="$("$repo_root"/install.sh --platform macos --dry-run --no-defaults)"
assert_contains "$no_defaults" 'Reversible macOS defaults: false'
if [[ "$no_defaults" == *'Apply reversible Dock'* ]]; then
  printf 'No-defaults dry run still planned preference mutation.\n' >&2
  exit 1
fi

# Tailscale is opt-in, uses the supported macOS app model (interactive
# login), and never reuses Fedora's systemd/tailscaled service assumptions.
no_tailscale="$("$repo_root"/install.sh --platform macos --dry-run)"
assert_contains "$no_tailscale" 'Tailscale networking profile: false'
if [[ "$no_tailscale" == *'Install the optional Tailscale profile'* ]]; then
  printf 'Default macOS dry run still planned the Tailscale profile.\n' >&2
  exit 1
fi
tailscale_dry_run="$("$repo_root"/install.sh --platform macos --dry-run --tailscale)"
assert_contains "$tailscale_dry_run" 'Tailscale networking profile: true'
assert_contains "$tailscale_dry_run" \
  'Install the optional Tailscale profile (Homebrew cask, interactive login).'
code_grep -Fq -- '--cask tailscale-app' "$macos_root/scripts/install-tailscale.sh"
code_grep -Fq -- '--tailscale' "$macos_root/scripts/verify.sh"
systemd_references="$(rg_matches -n 'systemctl|tailscaled\.service' \
  "$macos_root/scripts/install-tailscale.sh" "$macos_root/scripts/verify.sh")"
if [[ -n "$systemd_references" ]]; then
  printf 'macOS Tailscale profile reuses Fedora systemd/tailscaled assumptions.\n' >&2
  exit 1
fi
if code_grep -Fq 'tailscale up' "$macos_root/scripts/install-tailscale.sh"; then
  printf "macOS Tailscale installer runs 'tailscale up' automatically.\n" >&2
  exit 1
fi

# Homebrew owns machine tools/apps; mise retains portable runtimes and Lazygit.
for package in bash bat coreutils eza fd fzf gh git git-delta mise neovim ripgrep shellcheck sqlite starship stow tmux zoxide; do
  grep -Eq "^brew \"$package\"$" "$brewfile"
done
grep -Fq 'cask "ghostty"' "$brewfile"
grep -Fq 'cask "nikitabobko/tap/aerospace"' "$brewfile"
code_grep -Fq 'Intel Homebrew exists at /usr/local/bin/brew' \
  "$macos_root/scripts/install-system.sh"
for package in lazygit node python dotnet uv; do
  if grep -Eq "^brew \"$package\"$" "$brewfile"; then
    printf 'Portable mise-owned tool is duplicated in Brewfile: %s\n' "$package" >&2
    exit 1
  fi
done

# The selected manager is exclusive and preserves the Sway mental model.
unselected_managers="$(rg_matches -l -i 'yabai|skhd' "$macos_root" --glob '!docs/**')"
if [[ -n "$unselected_managers" ]]; then
  printf 'macOS implementation contains an unselected window manager.\n' >&2
  exit 1
fi
grep -Fq 'config-version = 2' "$config"
grep -Fq 'start-at-login = true' "$config"
grep -Fq 'auto-reload-config = true' "$config"
grep -Fq "persistent-workspaces = ['1', '2', '3', '4', '5', '6', '7', '8', '9']" "$config"

# after-login-command is not a real AeroSpace config key; only
# after-startup-command is. An unknown key fails `reload-config
# --warnings-as-errors` in verify.sh, so guard against reintroducing it.
if grep -Fq 'after-login-command' "$config"; then
  printf 'aerospace.toml sets the non-existent after-login-command key.\n' >&2
  exit 1
fi
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

# The same refusal, in the same words, as sway-workspace-grid: config/actions.tsv
# describes the two bindings identically, so they must behave identically.
refusal="$test_root/aerospace.err"
: >"$command_log"
status=0
MOCK_WORKSPACE=10 COMMAND_LOG="$command_log" PATH="$mock_bin:$PATH" \
  "$grid" right 2>"$refusal" || status=$?
((status == 1)) || {
  printf 'aerospace-workspace-grid exited %s outside the grid, expected 1.\n' "$status" >&2
  exit 1
}
grep -Fqx 'Focused workspace is not in the 1-9 grid: 10' "$refusal"
[[ ! -s "$command_log" ]] || {
  printf 'aerospace-workspace-grid switched workspace despite refusing.\n' >&2
  exit 1
}

# Defaults are inspectable and reversible without changing this Linux runner.
apply_plan="$("$macos_root"/scripts/apply-defaults.sh --dry-run)"
restore_plan="$("$macos_root"/scripts/apply-defaults.sh --restore --dry-run)"
assert_contains "$apply_plan" 'defaults write com.apple.dock autohide -bool true'
assert_contains "$apply_plan" 'defaults write com.apple.dock mru-spaces -bool false'
assert_contains "$restore_plan" 'defaults delete com.apple.dock autohide'
assert_contains "$restore_plan" 'defaults delete NSGlobalDomain KeyRepeat'

grep -Fq 'SIP and Gatekeeper remain enabled' "$repo_root/docs/platforms/macos.md"
grep -Fq 'Displays have separate Spaces' "$repo_root/docs/platforms/macos.md"
grep -Fq 'platforms/macos/scripts/apply-defaults.sh --restore' "$repo_root/docs/platforms/macos.md"

# The bindings themselves belong to config/actions.tsv and the reference it
# generates, not to a second table on the platform page. The platform page
# keeps the modifier rationale and points at that reference.
grep -Fq 'Control+Option' "$repo_root/docs/platforms/macos.md"
grep -Fq 'reference/keybindings.md' "$repo_root/docs/platforms/macos.md"
grep -Fq 'Command+Space' "$repo_root/config/actions.tsv"
grep -Fq 'Command+Space' "$repo_root/docs/reference/keybindings.md"

# The shared VimTeX fallback only reaches Okular or xdg-open, neither of
# which exists on macOS; a platform override is mandatory, matching the
# established platforms/fedora-wsl/stow/nvim-wsl pattern.
nvim_macos_plugin="$macos_root/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua"
[[ -f "$nvim_macos_plugin" ]] || {
  printf 'Missing macOS VimTeX viewer override: %s\n' "$nvim_macos_plugin" >&2
  exit 1
}
grep -Fq 'vim.g.vimtex_view_general_viewer = "open"' "$nvim_macos_plugin"
xdg_open_references="$(rg_matches -l 'xdg-open' "$macos_root")"
if [[ -n "$xdg_open_references" ]]; then
  printf 'macOS implementation references the Linux-only xdg-open.\n' >&2
  exit 1
fi
code_grep -Fq 'nvim-macos' "$macos_root/scripts/stow.sh"
code_grep -Fq 'nvim-macos' "$macos_root/scripts/verify.sh"
grep -Fq './scripts/test-dev-workflows.sh --latex' "$repo_root/docs/platforms/macos.md"
grep -Fq './install.sh --platform macos --dev-workflows' "$repo_root/docs/platforms/macos.md"

# gnubin supplies GNU tools macOS does not ship without shadowing Apple's
# coreutils. /etc/zprofile runs path_helper after .zshenv, so nothing set there
# keeps a fixed PATH index in a login shell: the verifier must assert tool
# resolution, and the PATH itself must leave Apple's tools in front.
platform_env="$macos_root/stow/zsh-platform/.config/zsh/platform-env.zsh"
code_grep -Fq 'timeout --version' "$macos_root/scripts/verify.sh" || {
  printf 'macOS verifier must assert a GNU timeout is available.\n' >&2
  exit 1
}
code_grep -Fq "shadows Apple's coreutils" "$macos_root/scripts/verify.sh" || {
  printf 'macOS verifier must assert Apple coreutils are not shadowed.\n' >&2
  exit 1
}
# shellcheck disable=SC2016 # Matching the literal expression in verify.sh.
if code_grep -Fq '${PATH%%:*}' "$macos_root/scripts/verify.sh"; then
  printf 'macOS verifier must not assert a fixed first PATH entry.\n' >&2
  exit 1
fi

gnubin_line="$(grep -n 'coreutils/libexec/gnubin' "$platform_env" | grep -v '^[0-9]*:#' | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016 # Matching the literal zsh array entry.
inherited_line="$(grep -n '^  \$path$' "$platform_env" | head -n1 | cut -d: -f1)"
if [[ -z "$gnubin_line" || -z "$inherited_line" ]]; then
  printf 'platform-env.zsh must list both the inherited path entry and gnubin.\n' >&2
  exit 1
fi
if ((gnubin_line < inherited_line)); then
  printf 'platform-env.zsh must append gnubin last so Apple coreutils win.\n' >&2
  exit 1
fi

# PATH is built by hand for the ordering reason above; everything else `brew
# shellenv` exports must still be exported, because scripts here read
# HOMEBREW_PREFIX to find Homebrew. Two of them fall back to /opt/homebrew when
# it is unset, so nothing fails today and nothing proved it was ever set.
for variable in HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY INFOPATH MANPATH; do
  code_grep -Eq "^\[ -z .*$variable|^export $variable=" "$platform_env" || {
    printf 'platform-env.zsh must export %s, as brew shellenv does.\n' "$variable" >&2
    exit 1
  }
done
# The verifier proves it on a real login shell rather than trusting the file.
code_grep -Fq 'HOMEBREW_PREFIX' "$macos_root/scripts/verify.sh" || {
  printf 'macOS verifier must assert the login shell exports HOMEBREW_PREFIX.\n' >&2
  exit 1
}
printf 'PASS: the macOS platform environment exports what brew shellenv does\n'

# The macOS verifier must reach OCaml through the one shared verifier, and must
# hand it the Homebrew prefix so opam ownership is provable rather than assumed
# from a PATH hit. A macOS-only OCaml check would be a second implementation.
macos_verifier="$macos_root/scripts/verify.sh"
code_grep -Fq 'common/verify-ocaml.sh' "$macos_verifier" || {
  printf 'macOS verifier does not run the shared OCaml verifier.\n' >&2
  exit 1
}
code_grep -Fq 'DOTFILES_NATIVE_PREFIX=' "$macos_verifier" || {
  printf 'macOS verifier does not pass its native prefix to the OCaml verifier.\n' >&2
  exit 1
}
if code_grep -Eq 'opam (switch|exec|var)' "$macos_verifier"; then
  printf 'macOS verifier duplicates OCaml checks instead of reusing the shared one.\n' >&2
  exit 1
fi
if code_grep -Fq -- '--ocaml' "$macos_verifier"; then
  printf 'macOS verifier takes a redundant --ocaml flag instead of reading state.\n' >&2
  exit 1
fi

# The macOS installer applies a theme, restores the Mason inventory and
# installs the pinned Catppuccin tmux plugin, so the verifier must check all
# three, and must prove mise ownership of the runtimes mise manages rather than
# accept whichever copy PATH finds. tests/test-macos-verification.sh runs these
# sections against a mocked machine; this asserts they stay in the file.
code_grep -Fq 'section "Theme"' "$macos_verifier" || {
  printf 'macOS verifier has no theme section.\n' >&2
  exit 1
}
# shellcheck disable=SC2016 # Matching the literal path expression in verify.sh.
code_grep -Fq 'theme_file="$XDG_CONFIG_HOME/dotfiles/theme"' "$macos_verifier" || {
  printf 'macOS verifier does not read the machine-local theme state.\n' >&2
  exit 1
}
# shellcheck disable=SC2016 # Matching the literal call in verify.sh.
code_grep -Fq 'check_mason_inventory "$DOTFILES_ROOT/nvim-lazyvim/.config/nvim/mason-packages.txt"' \
  "$macos_verifier" || {
  printf 'macOS verifier does not iterate the tracked Mason inventory.\n' >&2
  exit 1
}
code_grep -Fq 'check_catppuccin_tmux' "$macos_verifier" || {
  printf 'macOS verifier does not check the pinned Catppuccin tmux plugin.\n' >&2
  exit 1
}
# shellcheck disable=SC2016 # Matching the literal loop in verify.sh.
code_grep -Fq 'for name in "${mise_tools[@]}"; do check_mise_owned "$name"; done' "$macos_verifier" || {
  printf 'macOS verifier does not prove mise ownership of its runtimes.\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Platform consistency
#
# The manifest, the help text, the parser and the dry-run must advertise one
# capability set. A capability documented but unreachable, or installable but
# undeclared, is exactly the drift this asserts against.
# ---------------------------------------------------------------------------

manifest="$repo_root/config/capabilities.tsv"
macos_help="$("$repo_root/install.sh" --platform macos --help)"
macos_installer="$macos_root/install.sh"
# Read the manifest once: the loop body queries it again for dependency flags,
# and a redirection plus a nested read of the same file is a lint hazard.
manifest_rows="$(cat "$manifest")"

while IFS=$'\t' read -r capability platform _ cli_flag _ dependencies _ _ _ _ verifier _ _ docs _ status _; do
  [[ "$platform" == macos ]] || continue

  if [[ "$status" != implemented ]]; then
    [[ "$cli_flag" == - ]] ||
      { printf 'Unimplemented macOS capability %s still declares the flag %s.\n' \
        "$capability" "$cli_flag" >&2; exit 1; }
    continue
  fi

  [[ -f "$repo_root/$verifier" ]] ||
    { printf 'macOS capability %s names a verifier that does not exist: %s\n' \
      "$capability" "$verifier" >&2; exit 1; }
  [[ -f "$repo_root/${docs%%#*}" ]] ||
    { printf 'macOS capability %s names documentation that does not exist: %s\n' \
      "$capability" "$docs" >&2; exit 1; }

  [[ "$cli_flag" != - ]] || continue

  assert_contains "$macos_help" "$cli_flag"
  code_grep -Fq -- "  $cli_flag)" "$macos_installer" ||
    { printf 'macOS parser does not accept the implemented flag %s.\n' "$cli_flag" >&2; exit 1; }

  # A flag the manifest calls implemented must actually resolve a plan, with
  # whatever its declared dependencies require alongside it.
  selection=("$cli_flag")
  if [[ "$dependencies" != - ]]; then
    IFS=, read -r -a declared_dependencies <<<"$dependencies"
    for dependency in "${declared_dependencies[@]}"; do
      dependency_flag="$(awk -F '\t' -v c="$dependency" \
        '$1 == c && $2 == "macos" { print $4; exit }' "$manifest")"
      [[ "$dependency_flag" == - || -z "$dependency_flag" ]] ||
        selection=("$dependency_flag" "${selection[@]}")
    done
  fi
  "$repo_root/install.sh" --platform macos --dry-run "${selection[@]}" >/dev/null ||
    { printf 'macOS dry run rejected the implemented selection: %s\n' \
      "${selection[*]}" >&2; exit 1; }
done <<<"$manifest_rows"
printf 'macOS manifest, help, parser and dry run advertise one capability set.\n'

# --- The lock screen is the desktop wallpaper, and stays that way ---------
#
# macOS shows the desktop wallpaper when a logged-in session locks, and offers
# no documented user-level way to set the two separately. The only route to a
# distinct login-window image is writing into /Library/Caches/Desktop Pictures,
# a root-owned system cache whose layout is private; taking it would mean
# loosening permissions macOS maintains, which contradicts this platform's
# stated position on SIP and Gatekeeper. docs/platforms/macos.md records that
# under "Lock screen".
#
# A decision recorded only in prose is a decision the next change can walk
# past, so this is the guard. It forbids the rejected route rather than
# requiring that no lock-screen support ever exist: if a future macOS grows a
# supported interface, taking it will not trip this.
lock_screen_reach="$(
  grep -rInE 'Desktop Pictures|lockscreen\.png|-lock\.webp' \
    "$macos_root" || true
)"
[[ -z "$lock_screen_reach" ]] || {
  printf 'The macOS tree reaches for the login-window cache or the Swaylock\n' >&2
  printf 'assets. Both were rejected; see the "Lock screen" section of\n' >&2
  printf 'docs/platforms/macos.md before changing this.\n%s\n' \
    "$lock_screen_reach" >&2
  exit 1
}

# The rejection is only meaningful while the reasoning is on file, and while
# the assets it talks about still exist to be reached for.
grep -Fq '## Lock screen' "$repo_root/docs/platforms/macos.md" ||
  { printf 'docs/platforms/macos.md no longer records the lock-screen policy.\n' >&2
    exit 1; }
for flavour in latte frappe macchiato mocha; do
  [[ -f "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-$flavour-lock.webp" ]] ||
    { printf 'The %s lock asset is gone, so the macOS policy describes\n' "$flavour" >&2
      printf 'files that no longer exist.\n' >&2; exit 1; }
done
printf 'macOS leaves the lock screen to the desktop wallpaper.\n'

printf 'macOS profile configuration checks passed.\n'
