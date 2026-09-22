#!/usr/bin/env bash
set -euo pipefail

# The macOS verifier, run for real against a mocked Apple Silicon machine.
#
# A Linux runner cannot satisfy every macOS invariant: there is no
# /Applications, and the SFTP client is not Apple's /usr/bin OpenSSH. Those
# checks fail identically in every run here. Each case below therefore changes
# exactly one fact about an otherwise healthy fixture and asserts that the
# verifier reports exactly one more failure, naming the item that broke, so
# the environmental failures can never be what a case is proving.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
root="$TEST_ROOT"
home="$root/home"
config="$home/.config"
data="$home/.local/share"
mock_bin="$root/bin"
debugger="$root/easydotnet/tools/netcoredbg/osx-arm64/netcoredbg"
mkdir -p "$config/dotfiles" "$config/starship" "$config/zsh" "$config/git" \
  "$config/mise" "$config/nvim/lua/plugins" "$config/aerospace" "$config/ghostty" \
  "$home/.local/bin" "$data/mise/shims" "$mock_bin" "$(dirname "$debugger")"
touch "$debugger"
chmod +x "$debugger"

stub() {
  local name="$1"
  cat >"$mock_bin/$name"
  chmod +x "$mock_bin/$name"
}

# --- Apple Silicon platform --------------------------------------------------

stub brew <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --prefix ]] && printf '/opt/homebrew\n'
EOF
stub csrutil <<'EOF'
#!/usr/bin/env bash
printf 'System Integrity Protection status: enabled.\n'
EOF
# Models what the real spctl answers for this bundle rather than a boolean.
#
# The old stub exited 0 for any --assess, which is why the verifier's real
# defect was invisible to this suite for as long as it existed: on a real Mac
# `--assess --type execute` can never accept GhostPepper.app, because its
# Info.plist carries no CFBundlePackageType key and the execute assessment
# reads that key to decide whether a bundle is an application. It answers that
# the code is valid but the bundle does not seem to be an app, and exits 3.
# Only the install assessment reaches a verdict, so only it reports a source.
#
# Keeping that asymmetry here is what makes the suite fail if the verifier ever
# goes back to asking for an execute assessment.
stub spctl <<'EOF'
#!/usr/bin/env bash
assess=false
type=execute
target=""
while (($#)); do
  case "$1" in
  --status)
    printf 'assessments enabled\n'
    exit 0
    ;;
  --assess) assess=true ;;
  --type)
    type="$2"
    shift
    ;;
  --type=*) type="${1#--type=}" ;;
  --verbose*) ;;
  -*) ;;
  *) target="$1" ;;
  esac
  shift
done
[[ "$assess" == true ]] || exit 2
case "$type" in
execute)
  printf '%s: rejected (the code is valid but does not seem to be an app)\n' "$target"
  exit 3
  ;;
install)
  # A stand-in for an assessment that stalls reaching Apple's notarization
  # service, so the bound the verifier puts on this probe is exercised.
  [[ -z "${MOCK_SPCTL_ASSESS_SLEEP:-}" ]] || sleep "$MOCK_SPCTL_ASSESS_SLEEP"
  status="${MOCK_SPCTL_ASSESS_EXIT:-0}"
  if ((status == 0)); then
    printf '%s: accepted\n' "$target"
    printf 'source=%s\n' "${MOCK_SPCTL_ASSESS_SOURCE:-Notarized Developer ID}"
  else
    printf '%s: rejected\n' "$target"
  fi
  exit "$status"
  ;;
esac
exit 2
EOF
# The signature the optional dictation profile asserts. --display writes to
# standard error, the way the real codesign does, because that is what the
# verifier captures.
stub codesign <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--verify) exit "${MOCK_CODESIGN_VERIFY_EXIT:-0}" ;;
--display)
  printf 'Identifier=com.github.matthartman.ghostpepper\n' >&2
  printf 'TeamIdentifier=%s\n' "${MOCK_CODESIGN_TEAM:-$DICTATION_TEAM}" >&2
  ;;
esac
exit 0
EOF
# `defaults read <bundle>/Contents/Info CFBundleShortVersionString`, answered
# from the one-line fixture plist below.
stub defaults <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == read && "${3:-}" == CFBundleShortVersionString ]] || exit 1
plist="$2.plist"
[[ -f "$plist" ]] || exit 1
value="$(sed -n 's/^version=//p' "$plist" | head -n 1)"
[[ -n "$value" ]] || exit 1
printf '%s\n' "$value"
EOF
stub file <<'EOF'
#!/usr/bin/env bash
printf '%s: Mach-O 64-bit executable arm64\n' "${!#}"
EOF
stub dscl <<'EOF'
#!/usr/bin/env bash
printf 'UserShell: %s\n' "$MOCK_ZSH"
EOF
printf '%s\n' "$mock_bin/zsh" >"$root/shells"

# --- Homebrew and system commands -------------------------------------------

# git is the real one: the tmux plugin fixture below is a real checkout.
for command_name in delta eza fd fzf gh rg shellcheck sqlite3 \
  starship stow tmux zoxide aerospace; do
  ln -s /usr/bin/true "$mock_bin/$command_name"
done
# jq is the real one too: the Mason inventory check reads each package's
# receipt with it, and a jq that answers nothing would report every package as
# carrying a receipt that names no package.
jq_path="$(command -v jq)" ||
  _test_die 'jq is required: the Mason inventory check reads package receipts with it'
ln -s "$jq_path" "$mock_bin/jq"
# The verifier checks Neovim against the floor in config/tool-floors.tsv, so
# this fixture must report a version that parses; /usr/bin/true cannot, and a
# check that can only fail proves nothing.
stub nvim <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] || exit 0
printf 'NVIM v%s\n' "${MOCK_NVIM_VERSION:-0.12.5}"
EOF
stub ssh <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -V ]] && printf 'OpenSSH_9.9p2, LibreSSL 3.3.6\n' >&2
EOF
for command_name in scp sftp; do
  printf '#!/usr/bin/env bash\nprintf "usage: %s [-46] ...\\n" >&2\nexit 1\n' \
    "$command_name" | stub "$command_name"
done
stub bat <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --list-themes ]]; then
  printf 'Catppuccin Frappe\nCatppuccin Latte\nCatppuccin Macchiato\nCatppuccin Mocha\n'
fi
EOF

# mise activates its shims, and reports the installs directory of any tool it
# manages.
stub mise <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "activate bash" ]]; then
  printf 'export PATH=%q:"$PATH"\n' "$XDG_DATA_HOME/mise/shims"
elif [[ "${1:-}" == which ]]; then
  candidate="$XDG_DATA_HOME/mise/installs/$2/latest/bin/$2"
  [[ -x "$candidate" ]] || exit 1
  printf '%s\n' "$candidate"
fi
EOF

# A fresh Zsh login, reduced to what .zshrc derives from the machine-local
# theme state. MOCK_LOGIN_PATH_PREFIX models a directory, such as Homebrew's
# bin, that a real login would put ahead of the mise shims.
stub zsh <<'EOF'
#!/usr/bin/env bash
theme="$(tr -d '[:space:]' <"$XDG_CONFIG_HOME/dotfiles/theme" 2>/dev/null)"
bat_theme="Catppuccin ${theme^}"
login_path="${MOCK_LOGIN_PATH_PREFIX:+$MOCK_LOGIN_PATH_PREFIX:}$XDG_DATA_HOME/mise/shims:$PATH"
case "$*" in
*__DOTFILES_VERIFY_PATH__*) printf '\n__DOTFILES_VERIFY_PATH__%s\n' "$login_path" ;;
*__DOTFILES_VERIFY_THEME__*)
  printf '\n__DOTFILES_VERIFY_THEME__%s|%s\n' \
    "$XDG_CONFIG_HOME/starship/catppuccin-$theme.toml" "$bat_theme"
  ;;
esac
EOF

# --- mise-owned runtimes ------------------------------------------------------

mise_tool() {
  local name="$1" install_bin
  install_bin="$data/mise/installs/$name/latest/bin/$name"
  mkdir -p "$(dirname "$install_bin")"
  cat >"$install_bin"
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$data/mise/shims/$name"
  chmod +x "$data/mise/shims/$name"
}
for name in ast-grep lazygit neovim-node-host npm tree-sitter uv; do
  printf '#!/usr/bin/env bash\nexit 0\n' | mise_tool "$name"
done
mise_tool python <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -c ]] && printf 'arm64\n'
exit 0
EOF
mise_tool node <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -p ]] && printf 'arm64\n'
exit 0
EOF
mise_tool dotnet <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --info ]] && printf ' Architecture: arm64\n'
exit 0
EOF
mise_tool dotnet-easydotnet <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == healthcheck ]] || exit 0
printf '[{"type":"ok","name":"debugger.engine","value":"netcoredbg"},{"type":"ok","name":"debugger.source","value":"bundled"},{"type":"ok","name":"debugger.platform","value":"osx-arm64"},{"type":"ok","name":"debugger.path","value":"%s"},{"type":"ok","name":"debugger.version","value":"test"}]\n' \
  "$MOCK_EASY_DOTNET_DEBUGGER"
EOF

# --- Installed configuration -------------------------------------------------

ln -s "$repo_root/zsh/.zshenv" "$home/.zshenv"
ln -s "$repo_root/zsh/.config/zsh/.zshrc" "$config/zsh/.zshrc"
for file in platform-env.zsh platform.zsh; do
  ln -s "$repo_root/platforms/macos/stow/zsh-platform/.config/zsh/$file" "$config/zsh/$file"
done
ln -s "$repo_root/platforms/macos/stow/aerospace/.config/aerospace/aerospace.toml" \
  "$config/aerospace/aerospace.toml"
ln -s "$repo_root/platforms/macos/stow/aerospace/.local/bin/aerospace-workspace-grid" \
  "$home/.local/bin/aerospace-workspace-grid"
ln -s "$repo_root/git/.config/git/config" "$config/git/config"
ln -s "$repo_root/mise/.config/mise/config.toml" "$config/mise/config.toml"
ln -s "$repo_root/nvim-lazyvim/.config/nvim/init.lua" "$config/nvim/init.lua"
ln -s "$repo_root/platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua" \
  "$config/nvim/lua/plugins/macos.lua"
ln -s "$repo_root/platforms/macos/stow/ghostty-macos/.config/ghostty/macos.conf" \
  "$config/ghostty/macos.conf"

# The theme the installer applied: the state common/lib/theme-shared-state.sh
# writes, and the Stow-deployed Starship configuration for that flavour.
theme=macchiato
printf '%s\n' "$theme" >"$config/dotfiles/theme"
printf 'theme = catppuccin-%s.conf\n' "$theme" >"$config/dotfiles/ghostty.conf"
printf '[delta]\n    features = catppuccin-%s\n' "$theme" >"$config/dotfiles/git-theme"
printf 'set -g @catppuccin_flavor "%s"\n' "$theme" >"$config/dotfiles/tmux-theme.conf"
ln -s "$repo_root/starship/.config/starship/catppuccin-$theme.toml" \
  "$config/starship/catppuccin-$theme.toml"

# The tracked Mason inventory, installed. A package directory alone is not an
# installation -- Mason writes each package's receipt last -- so the fixture
# leaves behind what a finished install leaves behind.
mason_root="$data/nvim/mason/packages"
mason_packages=()
while IFS= read -r package; do
  [[ -n "$package" && "$package" != \#* ]] || continue
  mason_packages+=("$package")
done <"$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"
"$repo_root/tests/support/mason-mock-install.sh" \
  --pins "$repo_root/common/mason-package-versions.txt" "$data/nvim/mason" \
  "${mason_packages[@]}"

# The pinned Catppuccin tmux checkout.
tmux_plugin="$data/tmux/plugins/catppuccin"
tmux_pin="$(sed -n 's/^version="\(v[0-9][0-9.]*\)"$/\1/p' "$repo_root/common/install-tmux-theme.sh")"
mkdir -p "$tmux_plugin"
git -C "$tmux_plugin" init -q
printf '# theme\n' >"$tmux_plugin/catppuccin.tmux"
git -C "$tmux_plugin" add catppuccin.tmux
git -C "$tmux_plugin" -c user.name=Test -c user.email=test@example.invalid commit -qm theme
git -C "$tmux_plugin" tag "$tmux_pin"

# --- Optional dictation profile ----------------------------------------------
#
# The healthy fixture has the profile installed at the pinned version, signed
# by the pinned team and accepted by Gatekeeper, so each case below can break
# exactly one of those facts. The pin is read from the library rather than
# restated, so bumping the release does not silently stop testing anything.

read_dictation_pin() {
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" \
    "$repo_root/platforms/macos/lib/dictation.sh" | head -n 1
}
DICTATION_VERSION="$(read_dictation_pin DICTATION_GHOST_PEPPER_VERSION)"
DICTATION_TEAM="$(read_dictation_pin DICTATION_GHOST_PEPPER_TEAM_ID)"
DICTATION_APP_NAME="$(read_dictation_pin DICTATION_GHOST_PEPPER_APP)"
[[ -n "$DICTATION_VERSION" && -n "$DICTATION_TEAM" && -n "$DICTATION_APP_NAME" ]] ||
  _test_die 'could not read the Ghost Pepper pin'
export DICTATION_TEAM

applications="$root/applications"
dictation_app="$applications/$DICTATION_APP_NAME"
dictation_state="$config/dotfiles/macos-dictation.conf"
mkdir -p "$dictation_app/Contents/MacOS"
printf 'version=%s\n' "$DICTATION_VERSION" >"$dictation_app/Contents/Info.plist"
printf 'fixture\n' >"$dictation_app/Contents/MacOS/GhostPepper"
write_dictation_state() {
  cat >"$dictation_state" <<EOF_STATE
schema_version=2
profile=dictation
status=installed
application=ghost-pepper
provider=upstream-dmg
version=${1:-$DICTATION_VERSION}
EOF_STATE
}
write_dictation_state

# The deterministic mise context is install-time state that the verifier reads
# and never writes (issue #345), so the fixture provides it as an installed
# machine would.
macos_mise_context="$home/.local/state/dotfiles/mise-context"
mkdir -p "$macos_mise_context"

verify_environment=(
  env
  "HOME=$home"
  "USER=macos-test"
  "XDG_CONFIG_HOME=$config"
  "XDG_DATA_HOME=$data"
  "XDG_STATE_HOME=$home/.local/state"
  "PATH=$mock_bin:/usr/bin:/bin"
  "DOTFILES_TEST_UNAME_S=Darwin"
  "DOTFILES_TEST_UNAME_M=arm64"
  "DOTFILES_TEST_MACOS=true"
  "HOMEBREW_BIN=$mock_bin/brew"
  "SHELLS_FILE=$root/shells"
  "MOCK_ZSH=$mock_bin/zsh"
  "MOCK_EASY_DOTNET_DEBUGGER=$debugger"
  "MACOS_APPLICATIONS_DIR=$applications"
  "DICTATION_TEAM=$DICTATION_TEAM"
)

# run_verifier [VAR=value ...]: the verifier's output and failure count.
failures=0
run_verifier() {
  run_capture "${verify_environment[@]}" "$@" "$repo_root/platforms/macos/scripts/verify.sh"
  assert_failure
  [[ "$(sed $'s/\033\\[[0-9;]*m//g' <<<"$TEST_OUTPUT")" =~ macOS\ verification\ failed:\ ([0-9]+)\ failure ]] ||
    _test_die "the macOS verifier did not report a failure summary:\n$TEST_OUTPUT"
  failures="${BASH_REMATCH[1]}"
}

run_verifier
baseline_failures="$failures"
baseline_output="$TEST_OUTPUT"
for expected in \
  "Current Catppuccin flavour: $theme" \
  "Starship configuration selects the $theme palette" \
  'Delta local theme override matches' \
  'Ghostty local theme override matches' \
  'tmux local theme override matches' \
  'bat provides the selected syntax theme: Catppuccin Macchiato' \
  "Zsh login selects the $theme Starship configuration" \
  'Zsh login selects the Catppuccin Macchiato bat theme' \
  'Mason: lua-language-server' \
  "Catppuccin tmux is at the pinned $tmux_pin" \
  'dotnet is mise-managed via shim' \
  'node is mise-managed via shim' \
  'git runs:' \
  'scp runs:' \
  'Neovim 0.12.5 satisfies the >= 0.12 baseline' \
  "Ghost Pepper is at the pinned $DICTATION_VERSION" \
  'Ghost Pepper has no competing Homebrew cask' \
  "Ghost Pepper is signed by the pinned Developer ID team $DICTATION_TEAM" \
  'Gatekeeper accepts Ghost Pepper' \
  'Microphone and Accessibility consent is interactive'; do
  assert_contains "$baseline_output" "$expected"
done
# The fixture itself is healthy: nothing this suite proves fails in it.
for unexpected in 'Theme state' 'Starship configuration' 'theme override' \
  'bat does not' 'Zsh login STARSHIP_CONFIG' 'Zsh login BAT_THEME' 'Mason package' \
  'Catppuccin tmux is' 'resolves outside mise' 'does not run' \
  'does not satisfy'; do
  reported="$(grep -F -- "$unexpected" <<<"$baseline_output" || true)"
  if grep -Fq '✗' <<<"$reported"; then
    _test_die "the healthy macOS fixture failed a check this suite owns ($unexpected):\n$baseline_output"
  fi
done
printf 'PASS: a healthy macOS fixture passes the theme, Mason, tmux and mise ownership checks\n'

# expect_one_more_failure <description> <message>: the last run failed exactly
# one more check than the healthy fixture, and named it.
expect_one_more_failure() {
  assert_eq "$((baseline_failures + 1))" "$failures" "$1: failure count"
  assert_contains "$TEST_OUTPUT" "$2"
  printf 'PASS: %s\n' "$1"
}

# A Starship configuration for the wrong flavour: the theme was never applied.
ln -sfn "$repo_root/starship/.config/starship/catppuccin-mocha.toml" \
  "$config/starship/catppuccin-$theme.toml"
run_verifier
expect_one_more_failure 'a wrong catppuccin-*.toml fails verification' \
  "Starship configuration selects the $theme palette: expected 'palette = 'catppuccin_$theme''"
ln -sfn "$repo_root/starship/.config/starship/catppuccin-$theme.toml" \
  "$config/starship/catppuccin-$theme.toml"

mv "$config/dotfiles/git-theme" "$root/git-theme"
run_verifier
expect_one_more_failure 'a missing Delta theme override fails verification' \
  'Delta local theme override matches: expected'
mv "$root/git-theme" "$config/dotfiles/git-theme"

mv "$mason_root/lua-language-server" "$root/lua-language-server"
run_verifier
expect_one_more_failure 'a missing Mason package fails verification' \
  'Mason package not installed: lua-language-server'
mv "$root/lua-language-server" "$mason_root/lua-language-server"

# A package directory that exists but carries no finished installation is the
# state the verifier used to credit. Mason writes the receipt last, so removing
# it is exactly what an interrupted install leaves behind.
mv "$mason_root/marksman/mason-receipt.json" "$root/marksman-receipt.json"
run_verifier
expect_one_more_failure 'an unfinished Mason install fails verification' \
  'Mason package marksman is not completely installed'
mv "$root/marksman-receipt.json" "$mason_root/marksman/mason-receipt.json"

mv "$tmux_plugin" "$root/catppuccin-tmux"
run_verifier
expect_one_more_failure 'a missing Catppuccin tmux plugin fails verification' \
  'Catppuccin tmux is missing'
mv "$root/catppuccin-tmux" "$tmux_plugin"

# A plugin checkout moved past the pin still works: a warning, not a failure.
git -C "$tmux_plugin" -c user.name=Test -c user.email=test@example.invalid \
  commit -q --allow-empty -m 'past the pin'
run_verifier
assert_eq "$baseline_failures" "$failures" 'a Catppuccin tmux checkout past the pin: failure count'
assert_contains "$TEST_OUTPUT" "Catppuccin tmux is at $tmux_pin-1-g"
assert_contains "$TEST_OUTPUT" "not the pinned $tmux_pin"
printf 'PASS: a Catppuccin tmux checkout past the pin warns without failing verification\n'
git -C "$tmux_plugin" checkout -q --detach "$tmux_pin"

# A Homebrew dotnet ahead of the mise shim in the login PATH. It exists and
# runs, so the old presence check passed it.
homebrew_bin="$root/homebrew-bin"
mkdir -p "$homebrew_bin"
ln -s /usr/bin/true "$homebrew_bin/dotnet"
run_verifier "MOCK_LOGIN_PATH_PREFIX=$homebrew_bin"
expect_one_more_failure 'a Homebrew dotnet shadowing the mise-managed one fails verification' \
  "dotnet resolves outside mise in the configured login PATH: $homebrew_bin/dotnet"

# A Neovim below the declared floor. It resolves and runs, so the command
# probe above still passes it; only the floor check catches it.
run_verifier MOCK_NVIM_VERSION=0.11.9
expect_one_more_failure 'a Neovim below the declared floor fails verification' \
  'Neovim 0.11.9 does not satisfy the >= 0.12 baseline'

# A command that resolves but cannot start.
rm "$mock_bin/stow"
printf '#!/usr/bin/env bash\nexit 127\n' | stub stow
run_verifier
expect_one_more_failure 'a resolvable command that cannot run fails verification' \
  "stow resolves to $mock_bin/stow but does not run: 'stow --version' exited 127"

# --- Optional dictation profile: one broken fact at a time -------------------

# The previous case left a deliberately broken `stow` in place. Restore it, so
# the cases below are measured against the same healthy baseline as every
# other case rather than against one extra standing failure.
rm "$mock_bin/stow"
ln -s /usr/bin/true "$mock_bin/stow"

# expect_more_failures <count> <description> <message>
expect_more_failures() {
  assert_eq "$((baseline_failures + $1))" "$failures" "$2: failure count"
  assert_contains "$TEST_OUTPUT" "$3"
  printf 'PASS: %s\n' "$2"
}

# A build that is not the pinned one. It is installed, signed and accepted, so
# only the pin comparison catches it -- which is exactly what happens when
# Ghost Pepper's bundled Sparkle updater replaces the reviewed artifact.
printf 'version=99.0.0\n' >"$dictation_app/Contents/Info.plist"
run_verifier
expect_more_failures 1 'a Ghost Pepper build past the pin fails verification' \
  "Ghost Pepper reports 99.0.0, not the pinned $DICTATION_VERSION"
printf 'version=%s\n' "$DICTATION_VERSION" >"$dictation_app/Contents/Info.plist"

# A differently signed build under the same name.
run_verifier MOCK_CODESIGN_TEAM=ZZZZZZZZZZ
expect_more_failures 1 'a Ghost Pepper signed by another team fails verification' \
  "Ghost Pepper is signed by team ZZZZZZZZZZ, not the pinned $DICTATION_TEAM"

# A damaged signature.
run_verifier MOCK_CODESIGN_VERIFY_EXIT=1
expect_more_failures 1 "a damaged Ghost Pepper signature fails verification" \
  "Ghost Pepper's code signature does not verify"

# Gatekeeper refusing the bundle is a failure, and the message says not to
# resolve it by turning Gatekeeper off.
run_verifier MOCK_SPCTL_ASSESS_EXIT=3
expect_more_failures 1 'a Gatekeeper refusal fails verification' \
  'do not work around this by disabling Gatekeeper'
assert_contains "$TEST_OUTPUT" 'stripping the quarantine attribute'

# The verdict asserted is the notarization source, not the exit status. A
# Developer-ID-signed build Apple never notarized is accepted by Gatekeeper and
# exits 0, so a check that read only the status would pass exactly the artifact
# this one exists to reject.
run_verifier MOCK_SPCTL_ASSESS_SOURCE='Developer ID'
expect_more_failures 1 'an accepted but unnotarized build fails verification' \
  'Gatekeeper accepts Ghost Pepper, but not as a notarized build (source=Developer ID)'

# An assessment that never answers is reported as unobserved rather than as a
# notarization failure: it reaches Apple's notarization service, so a machine
# that cannot is not a machine with a bad application.
run_verifier DOTFILES_DICTATION_ASSESS_TIMEOUT=1 MOCK_SPCTL_ASSESS_SLEEP=5
assert_eq "$baseline_failures" "$failures" \
  'a Gatekeeper assessment that does not answer adds no failure'
assert_contains "$TEST_OUTPUT" 'did not answer within 1s'
printf 'PASS: %s\n' 'a stalled Gatekeeper assessment warns instead of failing'

# And spctl failing for a reason that is not a denial says so, rather than
# reporting a notarization failure the machine does not have. Status 2 is
# spctl's own code for arguments it will not act on -- which is what the
# execute assessment above would produce if the verifier ever asked for one on
# something spctl declines to classify.
run_verifier MOCK_SPCTL_ASSESS_EXIT=2
expect_more_failures 1 'an spctl that cannot assess is reported as such' \
  'The Gatekeeper assessment of Ghost Pepper could not be made; spctl exited 2'

# Recorded state that names a different release than the machine has.
write_dictation_state 1.0.0
run_verifier
expect_more_failures 1 'recorded dictation state past the pin fails verification' \
  "Recorded dictation state names 1.0.0, not the pinned $DICTATION_VERSION"
write_dictation_state

# An application present with no recorded state is an unowned copy: the
# profile was never selected, so nothing here owns what is installed.
mv "$dictation_state" "$root/macos-dictation.conf"
run_verifier
expect_more_failures 1 'an unowned Ghost Pepper copy fails verification' \
  'The dictation profile is not selected, but Ghost Pepper remains'

# A machine that never selected the profile passes, and says so.
mv "$dictation_app" "$root/GhostPepper.app"
run_verifier
assert_eq "$baseline_failures" "$failures" \
  'an unselected dictation profile: failure count'
assert_contains "$TEST_OUTPUT" 'Dictation profile is not installed (not selected)'
printf 'PASS: an unselected dictation profile verifies cleanly\n'
mv "$root/GhostPepper.app" "$dictation_app"
mv "$root/macos-dictation.conf" "$dictation_state"

# --- The verifier reads the mise context and never writes it ---------------
#
# docs/workflows/verification.md promises the verifier changes nothing. This
# is the one piece of persistent state it used to rebuild, and rebuilding it
# would delete the contamination the run exists to report.

printf '[tools]\nstray = "1"\n' >"$macos_mise_context/mise.toml"
stray_digest="$(sha256sum <"$macos_mise_context/mise.toml" | cut -d ' ' -f 1)"
run_verifier
assert_contains "$TEST_OUTPUT" 'mise resolution is not deterministic'
assert_contains "$TEST_OUTPUT" 'mise.toml'
assert_path_exists "$macos_mise_context/mise.toml"
assert_eq "$stray_digest" \
  "$(sha256sum <"$macos_mise_context/mise.toml" | cut -d ' ' -f 1)" \
  'the macOS verifier rewrote a stray declaration in the mise context'
printf 'PASS: the macOS verifier reports a contaminated mise context and leaves it in place\n'
rm -f "$macos_mise_context/mise.toml"

rm -rf "$macos_mise_context"
run_verifier
assert_contains "$TEST_OUTPUT" 'the deterministic mise context does not exist'
assert_path_missing "$macos_mise_context"
printf 'PASS: the macOS verifier reports a missing mise context instead of creating one\n'
mkdir -p "$macos_mise_context"

printf 'macOS verifier section tests passed.\n'
