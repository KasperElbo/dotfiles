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

# `list --cask` answers, rather than exiting non-zero the way this stub used to
# for everything but --prefix. A Homebrew that cannot answer is a real state the
# competing-cask check has to report as unobserved, so it is a case below and
# not the fixture's resting state (issue #396, GAP-24).
stub brew <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
"--prefix ")
  printf '/opt/homebrew\n'
  ;;
"list --cask")
  printf '%s' "${MOCK_BREW_CASKS:-}"
  exit "${MOCK_BREW_CASK_EXIT:-0}"
  ;;
*) exit 1 ;;
esac
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
# `defaults read`, answering both the dictation profile's version read and the
# managed-defaults section's per-key reads. The store is a fixture file, so a
# case can change or withdraw exactly one key. A key the store does not hold
# reports the way a never-written key does: non-zero, with nothing on stdout.
stub defaults <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == read ]] || exit 1
domain="${2:-}"
key="${3:-}"
if [[ "$key" == CFBundleShortVersionString ]]; then
  plist="$domain.plist"
  [[ -f "$plist" ]] || exit 1
  value="$(sed -n 's/^version=//p' "$plist" | head -n 1)"
  [[ -n "$value" ]] || exit 1
  printf '%s\n' "$value"
  exit 0
fi
[[ -f "${MOCK_DEFAULTS_DB:-}" ]] || exit 1
while IFS='|' read -r stored_domain stored_key stored_value; do
  [[ "$stored_domain" == "$domain" && "$stored_key" == "$key" ]] || continue
  printf '%s\n' "$stored_value"
  exit 0
done <"$MOCK_DEFAULTS_DB"
exit 1
EOF
# file(1), as the verifier calls it: `file -bL <path>`. -b is honoured here
# because suppressing the filename is the whole fix. While this stub prefixed
# every answer with the path, the netcoredbg fixture -- whose path ends in
# /tools/netcoredbg/osx-arm64/netcoredbg -- could not be given a non-arm64
# answer at all, so the suite could not express the case below (issue #390,
# GAP-19). MOCK_FILE_PATH names one file to describe differently, so a case
# changes one fact and the other architecture checks keep their verdicts.
stub file <<'EOF'
#!/usr/bin/env bash
brief=false
target=""
while (($#)); do
  case "$1" in
  -*) [[ "$1" != *b* ]] || brief=true ;;
  *) target="$1" ;;
  esac
  shift
done
description='Mach-O 64-bit executable arm64'
if [[ -n "${MOCK_FILE_PATH:-}" && "$target" == "$MOCK_FILE_PATH" ]]; then
  description="${MOCK_FILE_DESCRIPTION:-$description}"
fi
if [[ "$brief" == true ]]; then
  printf '%s\n' "$description"
else
  printf '%s: %s\n' "$target" "$description"
fi
EOF
# Podman, over an image store the suite owns. The store is a file rather than
# the stub's own idea of state, so a case can preload it and the suite can read
# back what the verifier left behind instead of taking the verifier's word for
# it (issue #372). The stub records every argv it is handed, which is how the
# --pull policy the probe chose is asserted.
stub podman <<'EOF'
#!/usr/bin/env bash
store="${MOCK_PODMAN_IMAGES:-}"
[[ -z "${MOCK_PODMAN_ARGV:-}" ]] || printf '%s\n' "$*" >>"$MOCK_PODMAN_ARGV"

image_id() {
  [[ -n "$store" && -f "$store" ]] || return 1
  awk -F '\t' -v name="$1" \
    '$1 == name { print $2; found = 1 } END { exit found ? 0 : 1 }' "$store"
}
forget_image() {
  [[ -n "$store" && -f "$store" ]] || return 1
  awk -F '\t' -v name="$1" '$1 != name' "$store" >"$store.next" &&
    mv "$store.next" "$store"
}

case "${1:-}" in
info)
  [[ "${2:-}" == --format ]] || exit 0
  printf 'true\n'
  ;;
image)
  [[ "${2:-}" == inspect ]] || exit 1
  shift 2
  [[ "${1:-}" != --format ]] || shift 2
  image_id "${1:-}" >/dev/null
  ;;
rmi)
  shift
  [[ "${1:-}" != --force ]] || shift
  image_id "${1:-}" >/dev/null || exit 1
  [[ "${MOCK_PODMAN_RMI_EXIT:-0}" == 0 ]] || exit "$MOCK_PODMAN_RMI_EXIT"
  forget_image "${1:-}"
  ;;
run)
  shift
  pull=missing
  while (($#)); do
    case "$1" in
    --rm) ;;
    --pull=*) pull="${1#--pull=}" ;;
    *) break ;;
    esac
    shift
  done
  image="${1:-}"
  if ! image_id "$image" >/dev/null; then
    if [[ "$pull" == never ]]; then
      printf 'Error: %s: image not known\n' "$image" >&2
      exit 125
    fi
    printf '%s\t%s\n' "$image" 'sha256:pulled-by-this-run' >>"$store"
  fi
  # A run that hangs after the pull, so a case can interrupt one.
  [[ -z "${MOCK_PODMAN_RUN_HANG:-}" ]] || sleep "$MOCK_PODMAN_RUN_HANG"
  [[ "${MOCK_PODMAN_RUN_EXIT:-0}" == 0 ]] || exit "$MOCK_PODMAN_RUN_EXIT"
  printf 'aarch64\n'
  ;;
*) exit 1 ;;
esac
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
ln -s "$repo_root/nvim-lazyvim/.config/nvim/lazy-lock.json" \
  "$config/nvim/lazy-lock.json"
ln -s "$repo_root/platforms/macos/stow/nvim-macos/.config/nvim/lua/plugins/macos.lua" \
  "$config/nvim/lua/plugins/macos.lua"
ln -s "$repo_root/platforms/macos/stow/ghostty-macos/.config/ghostty/macos.conf" \
  "$config/ghostty/macos.conf"
# The theme hook and the four wallpapers are Stow links like the rest, and this
# fixture deployed none of them, so five of the verifier's link checks had only
# ever been seen failing. A fixture that cannot show a link passing cannot show
# the wrong link failing either (issue #369).
mkdir -p "$config/dotfiles/theme-hooks.d" "$data/wallpapers"
ln -s "$repo_root/platforms/macos/stow/theme-hooks/.config/dotfiles/theme-hooks.d/macos.sh" \
  "$config/dotfiles/theme-hooks.d/macos.sh"
for wallpaper_flavour in latte frappe macchiato mocha; do
  ln -s "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-$wallpaper_flavour.webp" \
    "$data/wallpapers/catppuccin-$wallpaper_flavour.webp"
done

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

# The tracked Lazy lock file, installed. Same reasoning as the Mason inventory
# above: a plugin directory is what an interrupted clone leaves, so the fixture
# leaves real checkouts at the pinned commits, taken from the lock file the
# verifier reads.
"$repo_root/tests/support/lazy-mock-install.sh" \
  "$repo_root/nvim-lazyvim/.config/nvim/lazy-lock.json" "$data"

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

# --- Managed macOS defaults --------------------------------------------------
#
# The thirteen keys apply-defaults.sh writes, with the values `defaults read`
# answers for them. Derived from the installer's own array by a parse of its
# own, rather than from the verifier's reader, so a reader that had stopped
# seeing rows cannot agree with the fixture about what the set is.
macos_defaults_db="$root/defaults-db"
screenshot_directory="$home/Pictures/Screenshots"
awk -F '|' -v screenshots="$screenshot_directory" -v quote="'" '
  /^managed_defaults=\(/ { inside = 1; next }
  inside && /^\)/ { inside = 0 }
  !inside { next }
  {
    gsub("^[[:space:]]*" quote "|" quote "[[:space:]]*$", "")
    value = $4
    if (value == "__SCREENSHOT_DIRECTORY__") {
      value = screenshots
    } else if ($3 == "bool") {
      value = (value == "true") ? 1 : 0
    }
    print $1 "|" $2 "|" value
  }
' "$repo_root/platforms/macos/scripts/apply-defaults.sh" >"$macos_defaults_db"
# The six settings the old five-entry subset never read. If the installer stops
# writing one, this suite says so rather than quietly testing less.
for managed_key in tilesize orientation AppleShowAllFiles ShowStatusBar \
  location type KeyRepeat InitialKeyRepeat; do
  grep -q "|$managed_key|" "$macos_defaults_db" ||
    _test_die "the managed defaults fixture no longer covers $managed_key"
done

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
# verifier_flags holds the optional-section flags the run is made with; they go
# after the script, where env would otherwise read them as its own options.
failures=0
verifier_flags=()
run_verifier() {
  run_capture "${verify_environment[@]}" "$@" \
    "$repo_root/platforms/macos/scripts/verify.sh" \
    ${verifier_flags[@]+"${verifier_flags[@]}"}
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
  'Lazy plugins match ' \
  'Markdown preview server: ' \
  'Neovim starts and reports >= ' \
  "Ghost Pepper is at the pinned $DICTATION_VERSION" \
  'Ghost Pepper has no competing Homebrew cask' \
  "$config/git/config -> $repo_root/git/.config/git/config" \
  "$config/dotfiles/theme-hooks.d/macos.sh -> $repo_root/platforms/macos/stow/theme-hooks/.config/dotfiles/theme-hooks.d/macos.sh" \
  "$data/wallpapers/catppuccin-mocha.webp -> $repo_root/theme-assets/.local/share/wallpapers/catppuccin-mocha.webp" \
  "Ghost Pepper is signed by the pinned Developer ID team $DICTATION_TEAM" \
  'Gatekeeper accepts Ghost Pepper' \
  'Microphone and Accessibility consent is interactive'; do
  assert_contains "$baseline_output" "$expected"
done
# What the fixture cannot describe, named rather than counted. These are the
# only checks allowed to fail in it, so a check this suite owns that starts
# failing is reported here, and so is a check added to the verifier that fails
# on every run -- which a failure *count* absorbs silently. Issue #371 is what
# that costs: a plugin check was wired into this verifier, failed on every run
# from the first commit, and rode along inside baseline_failures.
macos_fixture_failures=(
  # The isolated PATH leads with this suite's mock bin, so the OpenSSH clients
  # resolve there rather than at Apple's /usr/bin.
  'sftp resolves to '
  'scp resolves to '
  'ssh resolves to '
  # No application bundles: the fixture is a filesystem, not a Mac.
  'Ghostty is missing: '
  'AeroSpace is missing: '
  'Ghostty application is missing'
  'AeroSpace application is missing'
  'AeroSpace loaded unexpected config: '
  # MOCK_ZSH is a stub, so a login shell reports neither the activation line
  # nor a Homebrew prefix.
  'Zsh login environment does not activate Starship and mise: '
  'Zsh login environment exports HOMEBREW_PREFIX='
)
assert_verifier_failures "$baseline_output" "${macos_fixture_failures[@]}"
printf 'PASS: a healthy macOS fixture passes the theme, Mason, tmux and mise ownership checks\n'

# The four application checks above are in that list because this fixture holds
# no bundles, and they belong to the fixture only if the verifier reads
# MACOS_APPLICATIONS_DIR. It used to name /Applications outright, so on a Mac
# with Ghostty and AeroSpace installed those four checks passed and the list
# above -- or, before it, the baseline count -- described the machine running
# the tests rather than the tree under test.
mkdir -p "$applications/Ghostty.app/Contents/MacOS" \
  "$applications/AeroSpace.app/Contents/MacOS"
printf '#!/bin/sh\nprintf "macos-option-as-alt = left\\n"\n' \
  >"$applications/Ghostty.app/Contents/MacOS/ghostty"
printf '#!/bin/sh\nexit 0\n' >"$applications/AeroSpace.app/Contents/MacOS/AeroSpace"
chmod +x "$applications/Ghostty.app/Contents/MacOS/ghostty" \
  "$applications/AeroSpace.app/Contents/MacOS/AeroSpace"
run_verifier
assert_contains "$TEST_OUTPUT" 'Ghostty application is installed'
assert_contains "$TEST_OUTPUT" 'Ghostty sends Left Option as Alt'
assert_contains "$TEST_OUTPUT" 'AeroSpace application is installed'
assert_not_contains "$TEST_OUTPUT" 'Ghostty is missing:'
assert_not_contains "$TEST_OUTPUT" 'AeroSpace is missing:'
rm -rf "$applications/Ghostty.app" "$applications/AeroSpace.app"
run_verifier
assert_eq "$baseline_failures" "$failures" 'the application fixture is removed again'
printf 'PASS: the application bundles are read where the fixture puts them, not in /Applications\n'

# expect_one_more_failure <description> <message>: the last run failed exactly
# one more check than the healthy fixture, and named it.
expect_one_more_failure() {
  assert_eq "$((baseline_failures + 1))" "$failures" "$1: failure count"
  assert_contains "$TEST_OUTPUT" "$2"
  printf 'PASS: %s\n' "$1"
}

# A plugin the lock file names and the tree does not. This is the case the
# verify-mode start exists for: before #371 a start that ran first would have
# installed it, and the plugin check that followed would have credited a
# machine the run had just repaired.
macos_withheld_plugin="$(jq -r 'keys[0]' \
  "$repo_root/nvim-lazyvim/.config/nvim/lazy-lock.json")"
mv "$data/nvim/lazy/$macos_withheld_plugin" "$root/withheld-plugin"
run_verifier
expect_one_more_failure 'a locked plugin missing from the tree is reported, not installed' \
  "Lazy plugin not installed: $macos_withheld_plugin"
mv "$root/withheld-plugin" "$data/nvim/lazy/$macos_withheld_plugin"

# The plugin at its locked commit with no preview server: what a headless
# install whose build never finished left, and a preview that opened nothing.
macos_preview_server="$data/nvim/lazy/markdown-preview.nvim/app/bin/$(bash -c 'source "$1/common/lib/markdown-preview.sh" && markdown_preview_server_name' _ "$repo_root")"
mv "$macos_preview_server" "$root/withheld-preview-server"
run_verifier
expect_one_more_failure 'a Markdown preview with no server is reported' \
  'Markdown preview server absent: '
mv "$root/withheld-preview-server" "$macos_preview_server"

# A Starship configuration for the wrong flavour: the theme was never applied.
ln -sfn "$repo_root/starship/.config/starship/catppuccin-mocha.toml" \
  "$config/starship/catppuccin-$theme.toml"
run_verifier
expect_one_more_failure 'a wrong catppuccin-*.toml fails verification' \
  "Starship configuration selects the $theme palette: expected 'palette = 'catppuccin_$theme''"
ln -sfn "$repo_root/starship/.config/starship/catppuccin-$theme.toml" \
  "$config/starship/catppuccin-$theme.toml"

# A link that resolves inside the package it is supposed to come from, at a
# file that is not the one Stow deploys there. Until the call sites passed the
# expected source, this was reported as owned and green: the git package holds
# both .config/git/config and the Delta theme it includes, so the redirected
# link satisfied "resolves somewhere below $DOTFILES_ROOT/git" (issue #369).
ln -sfn "$repo_root/git/.config/git/themes/catppuccin.gitconfig" "$config/git/config"
run_verifier
expect_one_more_failure 'a link to another file in the same package fails verification' \
  "$config/git/config is owned by $repo_root/git but is not the file Stow should have linked"
ln -sfn "$repo_root/git/.config/git/config" "$config/git/config"

# The same defect between two files that differ only in the flavour in their
# name: one shared theme-assets package holds all four wallpapers, so a mocha
# link pointing at the latte image was inside the expected root.
ln -sfn "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-latte.webp" \
  "$data/wallpapers/catppuccin-mocha.webp"
run_verifier
expect_one_more_failure 'a wallpaper link to another flavour fails verification' \
  "$data/wallpapers/catppuccin-mocha.webp is owned by $repo_root/theme-assets but is not the file Stow should have linked"
ln -sfn "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-mocha.webp" \
  "$data/wallpapers/catppuccin-mocha.webp"

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

# The previous case left a deliberately broken `stow` in place. Restore it, so
# the cases below are measured against the same healthy baseline as every
# other case rather than against one extra standing failure.
rm "$mock_bin/stow"
ln -s /usr/bin/true "$mock_bin/stow"

# --- Architecture checks read file(1)'s description, not its echo of the path -
#
# check_arm64_file matched `file -L` output, which begins with the path it was
# handed. The bundled debugger is checked at .../tools/netcoredbg/osx-arm64/
# netcoredbg, so "arm64" was guaranteed present in the text being matched and
# the check could not fail for an architecture reason (issue #390, GAP-19).

run_verifier "MOCK_FILE_PATH=$debugger" \
  'MOCK_FILE_DESCRIPTION=Mach-O 64-bit executable x86_64'
expect_one_more_failure 'an x86_64 bundled netcoredbg fails verification' \
  'EasyDotnet bundled netcoredbg does not report arm64 or universal architecture'

# The same check used to accept a download that is not an executable at all,
# for the same reason.
run_verifier "MOCK_FILE_PATH=$debugger" \
  'MOCK_FILE_DESCRIPTION=HTML document text'
expect_one_more_failure 'an HTML error page in place of netcoredbg fails verification' \
  'EasyDotnet bundled netcoredbg does not report arm64 or universal architecture'

# --- Managed macOS defaults: the whole set the installer writes --------------

verifier_flags=(--defaults)

# checked_defaults <output>: the domain|key pairs the run actually read back.
checked_defaults() {
  sed $'s/\033\\[[0-9;]*m//g' <<<"$1" |
    sed -n 's/^[^ ]* \(NSGlobalDomain\|com\.apple\.[a-z]*\) \([A-Za-z-]*\) \(=\|expected\) .*/\1|\2/p' |
    sort -u
}

run_verifier "MOCK_DEFAULTS_DB=$macos_defaults_db"
assert_eq "$baseline_failures" "$failures" \
  'a machine carrying every managed default: failure count'
assert_eq "$(cut -d '|' -f 1,2 <"$macos_defaults_db" | sort -u)" \
  "$(checked_defaults "$TEST_OUTPUT")" \
  'the managed defaults the verifier reads are exactly the ones apply-defaults.sh writes'
while IFS='|' read -r managed_domain managed_key managed_value; do
  assert_contains "$TEST_OUTPUT" "$managed_domain $managed_key = $managed_value"
done <"$macos_defaults_db"
printf 'PASS: every managed default the installer writes is read back\n'

# A screenshot default changed on the machine. The old five-entry subset named
# neither screencapture key, so this reported nothing.
sed 's#^com\.apple\.screencapture|type|png$#com.apple.screencapture|type|jpg#' \
  "$macos_defaults_db" >"$root/defaults-db-screenshot"
run_verifier "MOCK_DEFAULTS_DB=$root/defaults-db-screenshot"
expect_one_more_failure 'a changed screenshot format fails verification' \
  'com.apple.screencapture type expected png, got jpg'

# A keyboard default reverted to the system's own, which reads as unset.
grep -v '^NSGlobalDomain|KeyRepeat|' "$macos_defaults_db" \
  >"$root/defaults-db-keyrepeat"
run_verifier "MOCK_DEFAULTS_DB=$root/defaults-db-keyrepeat"
expect_one_more_failure 'a reverted key-repeat default fails verification' \
  'NSGlobalDomain KeyRepeat expected 2, got unset'

verifier_flags=()

# --- Optional dictation profile: one broken fact at a time -------------------

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

# A Homebrew that cannot answer is not a Homebrew that answered "no cask". The
# check used to discard both the status and stderr, so grep ran on the empty
# string and reported the absence of evidence as evidence of absence -- the one
# check in this section that did not fail closed (issue #396, GAP-24).
run_verifier MOCK_BREW_CASK_EXIT=2
assert_eq "$baseline_failures" "$failures" \
  'a Homebrew that cannot list casks: failure count'
assert_contains "$TEST_OUTPUT" 'Homebrew did not list its casks (exit 2)'
printf 'PASS: %s\n' 'a Homebrew that cannot list casks is unobserved, not a clean bill'

# And a cask that really does provide Ghost Pepper is still a failure.
run_verifier MOCK_BREW_CASKS=ghost-pepper
expect_more_failures 1 'a competing Homebrew cask fails verification' \
  'A Homebrew cask also provides Ghost Pepper'

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

# --- Container verification restores the image state it found ----------------
#
# `podman run` on an image this machine does not have pulls it and keeps it, so
# a check documented as read-only left a container image in local storage
# (issue #372). These cases read the image store itself, before and after, so
# what is asserted is the machine's state rather than the verifier's account of
# it -- the verifier deliberately makes no claim about this.

macos_podman_store="$root/podman-images"
macos_podman_argv="$root/podman-argv"
macos_smoke_image='docker.io/library/alpine:latest'

# run_container_verifier [VAR=value ...]: a --containers run, over an image
# store and an argv log this suite owns.
run_container_verifier() {
  : >"$macos_podman_argv"
  run_capture "${verify_environment[@]}" \
    "MOCK_PODMAN_IMAGES=$macos_podman_store" \
    "MOCK_PODMAN_ARGV=$macos_podman_argv" "$@" \
    "$repo_root/platforms/macos/scripts/verify.sh" --containers
}

# A machine that does not have the image. The probe pulls it, and storage is
# left as it was found.
: >"$macos_podman_store"
run_container_verifier
assert_contains "$TEST_OUTPUT" 'Containers run as ARM64'
assert_eq '' "$(cat "$macos_podman_store")" \
  'the image the smoke run introduced was left behind'
printf 'PASS: a smoke run removes the image it introduced\n'

# A machine that already has it. The tag must still name the same image ID
# afterwards, and the probe must not have gone looking for a newer one.
printf '%s\t%s\n' "$macos_smoke_image" 'sha256:the-copy-this-machine-had' \
  >"$macos_podman_store"
run_container_verifier
assert_contains "$TEST_OUTPUT" 'Containers run as ARM64'
assert_eq "$(printf '%s\t%s' "$macos_smoke_image" 'sha256:the-copy-this-machine-had')" \
  "$(cat "$macos_podman_store")" \
  'the image the machine already had did not survive verification unchanged'
assert_contains "$(cat "$macos_podman_argv")" '--pull=never'
printf 'PASS: an image the machine already had keeps its tag and its ID\n'

# A smoke run that fails after the pull. The verdict is a failure and storage
# is still restored.
: >"$macos_podman_store"
run_container_verifier MOCK_PODMAN_RUN_EXIT=1
assert_contains "$TEST_OUTPUT" 'Container architecture is unknown'
assert_eq '' "$(cat "$macos_podman_store")" \
  'a failed smoke run left the image it introduced behind'
printf 'PASS: a failed smoke run removes the image it introduced\n'

# An interruption. The stub pulls and then hangs, and the run is signalled, so
# the restore has to come from the handler rather than from the line after the
# probe -- which this run never reaches. SIGTERM rather than SIGINT, because a
# non-interactive shell starts a background job with SIGINT ignored and Bash
# will not install a trap for a signal that was ignored on entry, so a SIGINT
# here would prove nothing. The verifier traps all three of INT, TERM and HUP.
: >"$macos_podman_store"
"${verify_environment[@]}" "MOCK_PODMAN_IMAGES=$macos_podman_store" \
  MOCK_PODMAN_RUN_HANG=5 \
  "$repo_root/platforms/macos/scripts/verify.sh" --containers \
  >"$root/interrupted.log" 2>&1 &
interrupted_pid=$!
for _ in $(seq 1 200); do
  [[ -s "$macos_podman_store" ]] && break
  sleep 0.1
done
[[ -s "$macos_podman_store" ]] ||
  _test_die "the interrupted case never reached the smoke run:\n$(cat "$root/interrupted.log")"
kill -TERM "$interrupted_pid"
wait "$interrupted_pid" 2>/dev/null || true
assert_eq '' "$(cat "$macos_podman_store")" \
  'an interrupted verification left the image it introduced behind'
if grep -Fq 'macOS verification' "$root/interrupted.log"; then
  _test_die "the interrupted run reached its summary, so it was not interrupted:\n$(cat "$root/interrupted.log")"
fi
printf 'PASS: an interrupted smoke run removes the image it introduced\n'

# A removal that fails is said out loud rather than passed over, because the
# image is then still on the machine.
: >"$macos_podman_store"
run_container_verifier MOCK_PODMAN_RMI_EXIT=1
assert_contains "$TEST_OUTPUT" "Verification pulled $macos_smoke_image and could not remove it again"
printf 'PASS: an image that could not be removed again is reported\n'
: >"$macos_podman_store"

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
