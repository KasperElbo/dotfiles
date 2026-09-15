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
  "$config/mise" "$config/nvim/lua/plugins" "$config/aerospace" \
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
stub spctl <<'EOF'
#!/usr/bin/env bash
printf 'assessments enabled\n'
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
for command_name in delta eza fd fzf gh jq nvim rg shellcheck sqlite3 \
  starship stow tmux zoxide aerospace; do
  ln -s /usr/bin/true "$mock_bin/$command_name"
done
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

# The theme the installer applied: the state common/lib/theme-shared-state.sh
# writes, and the Stow-deployed Starship configuration for that flavour.
theme=macchiato
printf '%s\n' "$theme" >"$config/dotfiles/theme"
printf 'theme = catppuccin-%s.conf\n' "$theme" >"$config/dotfiles/ghostty.conf"
printf '[delta]\n    features = catppuccin-%s\n' "$theme" >"$config/dotfiles/git-theme"
printf 'set -g @catppuccin_flavor "%s"\n' "$theme" >"$config/dotfiles/tmux-theme.conf"
ln -s "$repo_root/starship/.config/starship/catppuccin-$theme.toml" \
  "$config/starship/catppuccin-$theme.toml"

# The tracked Mason inventory, installed.
mason_root="$data/nvim/mason/packages"
while IFS= read -r package; do
  [[ -n "$package" && "$package" != \#* ]] || continue
  mkdir -p "$mason_root/$package"
done <"$repo_root/nvim-lazyvim/.config/nvim/mason-packages.txt"

# The pinned Catppuccin tmux checkout.
tmux_plugin="$data/tmux/plugins/catppuccin"
tmux_pin="$(sed -n 's/^version="\(v[0-9][0-9.]*\)"$/\1/p' "$repo_root/common/install-tmux-theme.sh")"
mkdir -p "$tmux_plugin"
git -C "$tmux_plugin" init -q
printf '# theme\n' >"$tmux_plugin/catppuccin.tmux"
git -C "$tmux_plugin" add catppuccin.tmux
git -C "$tmux_plugin" -c user.name=Test -c user.email=test@example.invalid commit -qm theme
git -C "$tmux_plugin" tag "$tmux_pin"

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
  'scp runs:'; do
  assert_contains "$baseline_output" "$expected"
done
# The fixture itself is healthy: nothing this suite proves fails in it.
for unexpected in 'Theme state' 'Starship configuration' 'theme override' \
  'bat does not' 'Zsh login STARSHIP_CONFIG' 'Zsh login BAT_THEME' 'Mason package' \
  'Catppuccin tmux is' 'resolves outside mise' 'does not run'; do
  if grep -F -- "$unexpected" <<<"$baseline_output" | grep -Fq '✗'; then
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

rmdir "$mason_root/lua-language-server"
run_verifier
expect_one_more_failure 'a missing Mason package fails verification' \
  'Mason package not installed: lua-language-server'
mkdir -p "$mason_root/lua-language-server"

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

# A command that resolves but cannot start.
rm "$mock_bin/stow"
printf '#!/usr/bin/env bash\nexit 127\n' | stub stow
run_verifier
expect_one_more_failure 'a resolvable command that cannot run fails verification' \
  "stow resolves to $mock_bin/stow but does not run: 'stow --version' exited 127"

printf 'macOS verifier section tests passed.\n'
