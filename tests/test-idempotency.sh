#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# The mocked bootstrap leaves behind what a real Mason install leaves behind,
# so common/lib/mason.sh reads it as installed.
export MASON_MOCK_INSTALL="$repo_root/tests/support/mason-mock-install.sh"
export LAZY_MOCK_INSTALL="$repo_root/tests/support/lazy-mock-install.sh"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path git jq scp sftp sha256sum ssh stow timeout unlink
test_new_root
test_root="$TEST_ROOT"

command -v stow >/dev/null 2>&1 || {
  printf 'GNU Stow is required for idempotency tests.\n' >&2
  exit 1
}

repo_state="$(git -C "$repo_root" diff --binary HEAD | sha256sum)"

run_setup() {
  local home="$1"
  local flavour="$2"

  HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    "$repo_root/platforms/fedora/scripts/setup-local.sh" "$flavour" >/dev/null
}

run_stow() {
  local home="$1"

  HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    "$repo_root/platforms/fedora/scripts/stow.sh" >/dev/null
}

home="$test_root/home"
mkdir -p "$home/.config/git" "$home/.config/ghostty"
printf 'private identity\n' >"$home/.config/git/local"
printf 'user managed\n' >"$home/.config/ghostty/user.conf"
printf 'user target\n' >"$home/user-target"
ln -s user-target "$home/user-link"

run_setup "$home" macchiato
run_stow "$home"

first_identity="$(sha256sum "$home/.config/git/local")"
first_user_config="$(sha256sum "$home/.config/ghostty/user.conf")"
first_user_link="$(readlink "$home/user-link")"

run_setup "$home" macchiato
run_stow "$home"

[[ "$(sha256sum "$home/.config/git/local")" == "$first_identity" ]]
[[ "$(sha256sum "$home/.config/ghostty/user.conf")" == "$first_user_config" ]]
[[ "$(readlink "$home/user-link")" == "$first_user_link" ]]
[[ -L "$home/.config/git/config" ]]
[[ -L "$home/.config/ghostty/config" ]]
[[ -L "$home/.config/ghostty/shared.conf" ]]
printf 'PASS: repeated setup and Stow preserve local and unrelated state\n'

conflict_home="$test_root/conflict-home"
mkdir -p "$conflict_home"
printf 'keep this tmux config\n' >"$conflict_home/.tmux.conf"

if run_stow "$conflict_home" 2>"$test_root/stow-conflict.log"; then
  printf 'Expected Stow to reject a user-managed tracked path\n' >&2
  exit 1
fi

grep -Fqx 'keep this tmux config' "$conflict_home/.tmux.conf"
rm -- "$conflict_home/.tmux.conf"
run_stow "$conflict_home"
run_stow "$conflict_home"
[[ -L "$conflict_home/.tmux.conf" ]]
printf 'PASS: Stow conflicts are non-destructive and safely retryable\n'

# The scripts that own the mutation refuse on their own. Stow aborts on the
# first conflicting package, but only after the packages before it are linked,
# so a script run directly -- as the tests and the documented entry points do
# -- would otherwise leave a partly stowed HOME.
direct_home="$test_root/direct-home"
mkdir -p "$direct_home"
printf 'user-owned zshenv\n' >"$direct_home/.zshenv"
if HOME="$direct_home" \
  XDG_CONFIG_HOME="$direct_home/.config" \
  XDG_DATA_HOME="$direct_home/.local/share" \
  "$repo_root/common/stow.sh" >"$test_root/direct-stow.log" 2>&1; then
  printf 'A conflicting HOME unexpectedly passed common/stow.sh.\n' >&2; exit 1
fi
grep -Fq 'Stow conflict [zsh]: existing file or directory' "$test_root/direct-stow.log"
grep -Fqx 'user-owned zshenv' "$direct_home/.zshenv"
deployed="$(find "$direct_home" -mindepth 1 ! -path "$direct_home/.zshenv" -print)"
[[ -z "$deployed" ]] || {
  printf 'A refused stow created entries in HOME: %s\n' "$deployed" >&2; exit 1
}

# A package directory this checkout does not have is a missing package, not one
# to leave out. common/stow.sh used to warn, continue, print "Portable dotfiles
# stowed" and exit 0, so a checkout without the zsh package left HOME with no
# .zshrc and no .zshenv while the calling plan step reported completed. Both
# sibling Stow scripts die on the identical condition.
#
# The checkout is presented as a directory of symlinks rather than copied, so
# DOTFILES_ROOT -- which is logical -- is that directory and the zsh package is
# genuinely absent from it.
partial_root="$test_root/partial-checkout"
partial_home="$test_root/partial-home"
mkdir -p "$partial_root" "$partial_home"
for entry in "$repo_root"/*; do
  [[ "$(basename "$entry")" != zsh ]] || continue
  ln -s "$entry" "$partial_root/$(basename "$entry")"
done
if HOME="$partial_home" \
  XDG_CONFIG_HOME="$partial_home/.config" \
  XDG_DATA_HOME="$partial_home/.local/share" \
  "$partial_root/common/stow.sh" --headless \
  >"$test_root/partial-stow.log" 2>&1; then
  printf 'A checkout missing the zsh package unexpectedly passed common/stow.sh.\n' >&2
  exit 1
fi
grep -Fq 'Stow package is missing: zsh' "$test_root/partial-stow.log"
grep -Fq 'Refusing to stow' "$test_root/partial-stow.log"
partial_deployed="$(find "$partial_home" -mindepth 1 -print)"
[[ -z "$partial_deployed" ]] || {
  printf 'A refused stow created entries in HOME: %s\n' "$partial_deployed" >&2
  exit 1
}
printf 'PASS: a checkout missing a Stow package is refused, not skipped\n'

# A platform script checks its own packages before the portable ones are
# deployed, so a conflict in a platform package leaves nothing behind either.
platform_home="$test_root/platform-home"
theme_asset="$(find "$repo_root/theme-assets" -type f | head -n 1)"
theme_relative="${theme_asset#"$repo_root/theme-assets/"}"
mkdir -p "$platform_home/$(dirname "$theme_relative")"
printf 'user-owned asset\n' >"$platform_home/$theme_relative"
if HOME="$platform_home" \
  XDG_CONFIG_HOME="$platform_home/.config" \
  XDG_DATA_HOME="$platform_home/.local/share" \
  "$repo_root/platforms/fedora/scripts/stow.sh" >"$test_root/platform-stow.log" 2>&1; then
  printf 'A conflicting HOME unexpectedly passed the Fedora Stow script.\n' >&2; exit 1
fi
grep -Fq 'Stow conflict [theme-assets]' "$test_root/platform-stow.log"
grep -Fqx 'user-owned asset' "$platform_home/$theme_relative"
[[ ! -e "$platform_home/.zshenv" ]] || {
  printf 'A refused platform stow deployed the portable packages.\n' >&2; exit 1
}
printf 'PASS: the Stow scripts refuse before they change HOME\n'

# The migration this script carries exists for machines still holding the
# retired layout: top-level sway and waybar links, and wallpaper links the Sway
# package owned before theme-assets did. Every one of those either dangles or
# points into this checkout, so the preflight has to exempt the links the apply
# loop removes, or it refuses exactly the machines the migration repairs.
migration_home="$test_root/migration-home"
retired_sway="$migration_home/.config/sway/config"
retired_waybar="$migration_home/.config/waybar/style.css"
retired_wallpaper="$migration_home/.local/share/wallpapers/catppuccin-macchiato.webp"
fedora_stow_dir="$repo_root/platforms/fedora/stow"
mkdir -p "$(dirname "$retired_sway")" "$(dirname "$retired_waybar")" \
  "$(dirname "$retired_wallpaper")"
ln -s "$repo_root/sway/.config/sway/config" "$retired_sway"
ln -s "$repo_root/waybar/.config/waybar/style.css" "$retired_waybar"
ln -s "$fedora_stow_dir/sway/.local/share/wallpapers/catppuccin-macchiato.webp" \
  "$retired_wallpaper"

if ! HOME="$migration_home" \
  XDG_CONFIG_HOME="$migration_home/.config" \
  XDG_DATA_HOME="$migration_home/.local/share" \
  "$repo_root/platforms/fedora/scripts/stow.sh" --sway \
  >"$test_root/migration-stow.log" 2>&1; then
  printf 'The Fedora Stow script refused a HOME carrying the retired links:\n' >&2
  cat "$test_root/migration-stow.log" >&2
  exit 1
fi

assert_relinked() {
  local target="$1" source="$2"
  [[ "$(realpath "$target")" == "$(realpath "$source")" ]] || {
    printf 'Retired link was not rewritten: %s -> %s\n' \
      "$target" "$(readlink "$target")" >&2
    exit 1
  }
}
assert_relinked "$retired_sway" "$fedora_stow_dir/sway/.config/sway/config"
assert_relinked "$retired_waybar" "$fedora_stow_dir/waybar/.config/waybar/style.css"
assert_relinked "$retired_wallpaper" \
  "$repo_root/theme-assets/.local/share/wallpapers/catppuccin-macchiato.webp"
printf 'PASS: the Fedora preflight exempts the retired links its migration removes\n'

tracked_config="$repo_root/ghostty/.config/ghostty/config"
tracked_hash="$(sha256sum "$tracked_config")"
unlink "$home/.config/dotfiles/ghostty.conf"
ln -s "$tracked_config" "$home/.config/dotfiles/ghostty.conf"

run_setup "$home" macchiato

[[ "$(sha256sum "$tracked_config")" == "$tracked_hash" ]]
[[ -f "$home/.config/dotfiles/ghostty.conf" ]]
[[ ! -L "$home/.config/dotfiles/ghostty.conf" ]]

theme_bin="$test_root/theme-bin"
mkdir -p "$theme_bin"
for command in bash basename cat chmod dirname mkdir mktemp mv readlink; do
  ln -s "$(command -v "$command")" "$theme_bin/$command"
done

HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" \
  XDG_DATA_HOME="$home/.local/share" \
  PATH="$theme_bin" \
  "$home/.local/bin/theme" mocha >/dev/null

grep -Fqx mocha "$home/.config/dotfiles/theme"
grep -Fqx 'theme = catppuccin-mocha.conf' \
  "$home/.config/dotfiles/ghostty.conf"
[[ "$(sha256sum "$tracked_config")" == "$tracked_hash" ]]
[[ "$(git -C "$repo_root" diff --binary HEAD | sha256sum)" == "$repo_state" ]]
printf 'PASS: generated state and theme switching do not modify tracked files\n'

legacy_home="$test_root/legacy-home"
mkdir -p "$legacy_home/.config"
ln -s "$repo_root/git/.config/git" "$legacy_home/.config/git"

run_setup "$legacy_home" frappe

[[ -d "$legacy_home/.config/git" ]]
[[ ! -L "$legacy_home/.config/git" ]]

# No migration source is configured for this fixture, so each slot must become
# a machine-local file that states plainly that nothing was migrated — never an
# empty file that looks like a successful migration, and never a fabricated
# [user] section. tests/test-git-identity.sh covers the recoverable cases.
for identity in local drdk; do
  identity_path="$legacy_home/.config/git/$identity"
  [[ -f "$identity_path" && ! -L "$identity_path" ]]
  [[ -s "$identity_path" ]]
  grep -Fq 'No Git identity was migrated into this file' "$identity_path"
  grep -Fq '[user]' "$identity_path" && exit 1
  [[ "$(stat -c '%a' "$identity_path")" == 600 ]]
done

run_stow "$legacy_home"
run_stow "$legacy_home"
[[ -L "$legacy_home/.config/git/config" ]]
[[ "$(git -C "$repo_root" diff --binary HEAD | sha256sum)" == "$repo_state" ]]
printf 'PASS: legacy folded Git layout migrates safely and remains repeatable\n'

bootstrap_home="$test_root/bootstrap-home"
bootstrap_config="$bootstrap_home/.config"
bootstrap_data="$bootstrap_home/.local/share"
bootstrap_cache="$bootstrap_home/.cache"
stub_root="$test_root/bootstrap-stubs"
mock_bin="$stub_root/bin"
shell_state="$test_root/login-shell"
# The verifier expects the bundled debugger for the host's own architecture.
case "$(uname -m)" in aarch64 | arm64) debugger_rid=linux-arm64 ;; *) debugger_rid=linux-x64 ;; esac
debugger_path="$test_root/easydotnet/tools/netcoredbg/$debugger_rid/netcoredbg"
mkdir -p \
  "$bootstrap_config/git" \
  "$bootstrap_data/tmux/plugins" \
  "$bootstrap_cache" \
  "$(dirname "$debugger_path")" \
  "$mock_bin"
printf '/bin/bash\n' >"$shell_state"
touch "$debugger_path"
chmod +x "$debugger_path"

test_stub_init "$stub_root"
test_stub_install "$stub_root" sudo
test_stub_allow "$stub_root" sudo -n -v
test_stub_allow "$stub_root" sudo dnf install -y \
  bat curl eza fd-find fzf firewalld gh git git-delta gnupg2 jq libicu neovim \
  openssh-clients ripgrep ShellCheck shadow-utils sqlite sqlite-devel stow \
  tmux unzip wl-clipboard xdg-utils zoxide zsh zsh-autosuggestions \
  zsh-syntax-highlighting
test_stub_allow "$stub_root" sudo dnf install -y ghostty mise starship
test_stub_allow "$stub_root" sudo usermod --shell "$mock_bin/zsh" fedora-test
test_stub_allow "$stub_root" sudo dnf install -y \
  qemu-guest-agent spice-vdagent xclip
test_stub_allow "$stub_root" sudo systemctl enable --now \
  qemu-guest-agent.service
test_stub_allow "$stub_root" sudo systemctl enable --now firewalld.service
test_stub_allow "$stub_root" sudo systemctl start spice-vdagentd.socket

cat >"$mock_bin/mock-command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# The Fedora verifier re-checks the Terra trust root: the keyring holds one
# fixture key, which the gpg stub reads back as the fingerprint pinned for the
# fixture release in TERRA_KEY_MANIFEST.
terra_fixture_fingerprint=1111111111111111111111111111111111111111
printf '90\t%s\n' "$terra_fixture_fingerprint" >"$test_root/terra-keys.tsv"

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  '-q terra-release' | '-q qemu-guest-agent' | '-q spice-vdagent' | '-q xclip' | '-q openssh-clients') exit 0 ;;
  '-q gpg-pubkey')
    printf 'fixture-key:1111111111111111111111111111111111111111\n'
    exit 0
    ;;
  '-E %fedora')
    printf '90\n'
    exit 0
    ;;
esac

# File-ownership queries: verification asks which package owns the command
# that actually resolved, so the stub answers for the OpenSSH client binaries
# exactly as Fedora's package database would. Any other path stays unowned.
if [[ "$1" == -qf ]]; then
  case "${!#}" in
  */ssh | */scp | */sftp)
    printf 'openssh-clients'
    exit 0
    ;;
  esac
fi
exit 1
EOF

cat >"$stub_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == usermod && "$2" == --shell ]]; then
  printf '%s\n' "$3" >"$SHELL_STATE"
fi
exit 0
EOF

cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '1000\n' ;;
  -un) printf 'fedora-test\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == passwd && "${2:-}" == fedora-test ]]; then
  printf 'fedora-test:x:1000:1000:Fedora Test:/home/fedora-test:%s\n' \
    "$(<"$SHELL_STATE")"
else
  /usr/bin/getent "$@"
fi
EOF

# The preflight disk floor decides on a known figure rather than on whatever
# this machine happens to have free.
test_stub_roomy_df "$mock_bin"

cat >"$mock_bin/terra-dnf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --dump-repo-config=terra ]]; then
  printf 'gpgcheck = 1\npkg_gpgcheck = 1\n'
fi
exit 0
EOF

cat >"$mock_bin/terra-gpg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '--show-keys --with-colons' ]]; then
  awk -F: '$1 == "fixture-key" {
    print "pub:-:4096:1:0000000000000000:0:::-:::scESC::::::23::0:"
    print "fpr:::::::::" $2 ":"
  }'
fi
exit 0
EOF

chmod +x \
  "$mock_bin/mock-command" \
  "$mock_bin/terra-dnf" \
  "$mock_bin/terra-gpg" \
  "$mock_bin/rpm" \
  "$mock_bin/id" \
  "$mock_bin/getent" \
  "$mock_bin/df" \
  "$stub_root/handlers/sudo"

mock_commands=(
  ast-grep
  bat
  curl
  delta
  dnf
  dotnet
  dotnet-easydotnet
  eza
  fd
  fzf
  gh
  ghostty
  gpg
  lazygit
  lookandfeeltool
  makoctl
  neovim-node-host
  node
  pgrep
  pkill
  plasma-apply-colorscheme
  plasma-apply-cursortheme
  python
  rg
  shellcheck
  sqlite3
  starship
  systemctl
  swaymsg
  tmux
  tree-sitter
  uv
  wl-copy
  wl-paste
  zoxide
  zsh
)

for command_name in "${mock_commands[@]}"; do
  ln -s mock-command "$mock_bin/$command_name"
done
ln -sf terra-dnf "$mock_bin/dnf"
ln -sf terra-gpg "$mock_bin/gpg"

rm -- "$mock_bin/zsh"
cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
# A login inherits PATH, and .zshenv puts ~/.local/bin in front of it. Every
# login then reads the zsh package's .zprofile, which puts mise's shims behind
# ~/.local/bin when the directory exists; only an interactive login goes on to
# read .zshrc, which activates mise and so puts it ahead of both. Modelled from
# the files this home actually has: a home with no .zprofile -- a zsh package
# stowed before the file existed -- gives a login that is not interactive no
# shims at all, and that is what lets a dnf copy of a mise-owned runtime hide
# from the interactive probe (issue #507, V4-11).
mise_shims="$XDG_DATA_HOME/mise/shims"
if [[ "${1:-}" == +m && "${2:-}" == -lc ]]; then
  if [[ -e "${XDG_CONFIG_HOME:-$HOME/.config}/zsh/.zprofile" && -d "$mise_shims" ]]; then
    login_path="$HOME/.local/bin:$mise_shims:$PATH"
  else
    login_path="$HOME/.local/bin:$PATH"
  fi
else
  login_path="$mise_shims:$HOME/.local/bin:$PATH"
fi
if [[ "$*" == *'login-path:'* ]]; then
  # The shared verifier library asks for a login PATH through this marker:
  # check_mise_owned asks a login that is not interactive, whichever verifier
  # calls it.
  printf 'login-path:%s\n' "$login_path"
elif [[ "$*" == *'printf "%s\\n" "$PATH"'* ]]; then
  # The mise section of platforms/fedora/scripts/verify.sh asks for the same
  # PATH without a marker, so both spellings have to be answered here.
  printf '%s\n' "$login_path"
fi
exit 0
EOF
chmod +x "$mock_bin/zsh"

rm -- "$mock_bin/dotnet-easydotnet"
cat >"$mock_bin/dotnet-easydotnet" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == healthcheck ]]; then
  platform="$(basename "$(dirname "$MOCK_EASY_DOTNET_DEBUGGER")")"
  printf '[{"type":"ok","name":"debugger.engine","value":"netcoredbg"},{"type":"ok","name":"debugger.source","value":"bundled"},{"type":"ok","name":"debugger.platform","value":"%s"},{"type":"ok","name":"debugger.path","value":"%s"},{"type":"ok","name":"debugger.version","value":"NET Core debugger test version"}]\n' \
    "$platform" "$MOCK_EASY_DOTNET_DEBUGGER"
fi
EOF
chmod +x "$mock_bin/dotnet-easydotnet"

cat >"$mock_bin/mise" <<'EOF'
#!/usr/bin/env bash
# Every call this fixture does not implement is refused. It used to fall off
# the end of the chain into a bare `exit 0`, which answered three real calls
# with silence: `--yes install` installed nothing and reported success, bare
# `mise ls` satisfied the Fedora verifier's "mise configuration loads
# successfully" check without loading anything, and `--version` returned an
# empty string. A refusal is how a new call announces that this stub has to
# decide what it means.
reject() {
  printf 'strict mise fixture rejected unsupported argv:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
}

if [[ "${1:-}" == exec && "${2:-}" == -- && $# -ge 3 ]]; then
  shift 2
  exec "$@"
elif [[ "${1:-}" == which && $# -eq 2 ]]; then
  command -v "$2"
  exit $?
elif [[ "${1:-}" == --version && $# -eq 1 ]]; then
  printf '2025.1.0 linux-x64 (fixture)\n'
  exit 0
elif [[ "${1:-}" == --yes && "${2:-}" == install && $# -eq 2 ]]; then
  # Deliberately a no-op that says so. This suite is about Stow deployment and
  # state repeatability, and it resolves tools through `which` off the mock
  # PATH; tool installation is tests/test-mise-context.sh's subject. Accepting
  # it here is a decision rather than a fall-through.
  exit 0
elif [[ "${1:-}" == ls && $# -eq 1 ]]; then
  # The Fedora verifier's configuration-loads check reads the status only.
  exit 0
fi
reject "$@"
EOF
chmod +x "$mock_bin/mise"

cat >"$mock_bin/nvim" <<'EOF'
#!/usr/bin/env bash
# The installer checks the Neovim floor before any bootstrap phase. Answer it
# here, at the floor config/tool-floors.tsv declares, and do not let the probe
# count as a bootstrap invocation.
if [[ "${1:-}" == --version ]]; then
  printf 'NVIM v0.12.5\n'
  exit 0
fi
for argument in "$@"; do
  if [[ "$argument" == '+Lazy! restore mason.nvim' ]]; then
    mkdir -p "$XDG_DATA_HOME/nvim/lazy/mason.nvim"
  fi

  # A real '+Lazy! restore' checks out every plugin the profile's lock file
  # names. A fixture that stopped at mason.nvim would model a machine whose
  # plugin tree was never restored, and the verifier is right to fail that.
  if [[ "$argument" == '+Lazy! restore' ]]; then
    "${LAZY_MOCK_INSTALL:?the suite must export the Lazy install fixture}" \
      "$XDG_CONFIG_HOME/nvim/lazy-lock.json" "$XDG_DATA_HOME"
  fi

  if [[ "$argument" == */common/bootstrap-mason.lua ]]; then
    # A real install leaves a receipt, a payload and a bin link behind, and
    # common/lib/mason.sh reads all three; a directory alone is what an
    # interrupted install leaves, so the mock must not stop there.
    "${MASON_MOCK_INSTALL:?the suite must export the Mason install fixture}" \
      "$XDG_DATA_HOME/nvim/mason" \
      ${DOTFILES_MASON_REPAIR_PACKAGES:-} ${DOTFILES_MASON_PACKAGES:-}
  fi
done
EOF
chmod +x "$mock_bin/nvim"

cat >"$mock_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
printf 'kvm\n'
EOF
chmod +x "$mock_bin/systemd-detect-virt"

cat >"$mock_bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'default via 192.168.122.1 dev enp1s0 proto dhcp\n'
EOF
chmod +x "$mock_bin/ip"

virtio_ports="$test_root/virtio-ports"
mkdir -p "$virtio_ports"
touch \
  "$virtio_ports/org.qemu.guest_agent.0" \
  "$virtio_ports/com.redhat.spice.0"

theme_origin="$test_root/tmux-theme-origin"
mkdir -p "$theme_origin"
git -C "$theme_origin" init -q
git -C "$theme_origin" config user.name Bootstrap-Test
git -C "$theme_origin" config user.email bootstrap@example.invalid
printf '# test theme\n' >"$theme_origin/catppuccin.tmux"
git -C "$theme_origin" add catppuccin.tmux
git -C "$theme_origin" commit -qm 'Add test theme'
git -C "$theme_origin" tag v2.3.0

theme_install="$bootstrap_data/tmux/plugins/catppuccin"
git clone -q "$theme_origin" "$theme_install"

printf 'ID=fedora\n' >"$test_root/os-release"
printf '[user]\n    name = Private User\n' >"$bootstrap_config/git/local"
printf 'unrelated bootstrap state\n' >"$bootstrap_home/notes"

bootstrap_environment=(
  env
  "HOME=$bootstrap_home"
  "XDG_CONFIG_HOME=$bootstrap_config"
  "XDG_DATA_HOME=$bootstrap_data"
  "XDG_CACHE_HOME=$bootstrap_cache"
  "OS_RELEASE_FILE=$test_root/os-release"
  "TERRA_KEY_MANIFEST=$test_root/terra-keys.tsv"
  # The runner's own DNF repositories (a jdxcode/mise COPR, say) would change
  # the Terra transaction this suite pins.
  "DNF_REPO_DIR=$test_root/yum.repos.d"
  "QEMU_AGENT_CHANNEL=$virtio_ports/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$virtio_ports/com.redhat.spice.0"
  "SHELL_STATE=$shell_state"
  "TEST_STUB_ROOT=$stub_root"
  "MOCK_EASY_DOTNET_DEBUGGER=$debugger_path"
  "PATH=$mock_bin:$PATH"
)

run_bootstrap() {
  local output="$test_root/bootstrap.log"

  if ! "${bootstrap_environment[@]}" \
    "$repo_root/install.sh" \
    --theme macchiato --no-kde --no-latex --non-interactive \
    "$@" \
    >"$output" 2>&1; then
    printf 'Complete mocked bootstrap failed:\n' >&2
    sed -n '1,240p' "$output" >&2
    exit 1
  fi
}

run_bootstrap

grep -Fqx "$mock_bin/zsh" "$shell_state"
grep -Fq 'reboot before expecting Ghostty to use' "$test_root/bootstrap.log"

bootstrap_identity="$(sha256sum "$bootstrap_config/git/local")"
bootstrap_notes="$(sha256sum "$bootstrap_home/notes")"

run_bootstrap

grep -Fqx "$mock_bin/zsh" "$shell_state"

[[ "$(sha256sum "$bootstrap_config/git/local")" == "$bootstrap_identity" ]]
[[ "$(sha256sum "$bootstrap_home/notes")" == "$bootstrap_notes" ]]
[[ -L "$bootstrap_config/git/config" ]]
[[ -L "$bootstrap_home/.local/bin/theme" ]]
printf 'PASS: a complete mocked bootstrap succeeds twice without side effects\n'

printf '/bin/bash\n' >"$shell_state"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/login-shell-verification.log" 2>&1; then
  printf 'Fedora verification accepted Bash as the configured login shell\n' >&2
  exit 1
fi
grep -Fq 'Default login shell is not Zsh: /bin/bash' \
  "$test_root/login-shell-verification.log"
printf '%s\n' "$mock_bin/zsh" >"$shell_state"
printf 'PASS: Fedora verification rejects a non-Zsh login shell\n'

rm -f -- "$theme_install/catppuccin.tmux"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/tmux-missing-verification.log" 2>&1; then
  printf 'Fedora verification accepted a missing Catppuccin tmux plugin\n'
  exit 1
fi
grep -Fq 'Catppuccin tmux is missing' "$test_root/tmux-missing-verification.log"
git -C "$theme_install" checkout -q -- catppuccin.tmux
printf 'PASS: Fedora verification rejects a missing Catppuccin tmux plugin\n'

git -C "$theme_install" -c user.name=Bootstrap-Test -c user.email=bootstrap@example.invalid \
  commit -q --allow-empty -m 'past the pin'
if ! "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/tmux-drift-verification.log" 2>&1; then
  printf 'Fedora verification failed a Catppuccin tmux checkout past the pin:\n'
  cat "$test_root/tmux-drift-verification.log"
  exit 1
fi
grep -Fq 'Catppuccin tmux is at v2.3.0-1-g' "$test_root/tmux-drift-verification.log"
grep -Fq 'not the pinned v2.3.0' "$test_root/tmux-drift-verification.log"
git -C "$theme_install" checkout -q --detach v2.3.0
printf 'PASS: Fedora verification warns about a Catppuccin tmux checkout past the pin\n'

# The two questions #371 added to this verifier, asserted on the run above,
# which is the only one here that has to succeed. Without these a check that
# quietly stopped running would still read as a clean machine.
grep -Fq 'Lazy plugins match ' "$test_root/tmux-drift-verification.log"
grep -Fq 'Neovim starts and reports >= ' "$test_root/tmux-drift-verification.log"
printf 'PASS: Fedora verification reports Lazy plugin state and a bounded Neovim start\n'

# Negative control for the pair. A plugin the lock file names and the tree does
# not is exactly what the start used to install before it was answered for, so
# it has to be reported here rather than repaired.
withheld_plugin="$(jq -r 'keys[0]' "$bootstrap_config/nvim/lazy-lock.json")"
mv "$bootstrap_data/nvim/lazy/$withheld_plugin" "$test_root/withheld-plugin"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/lazy-missing-verification.log" 2>&1; then
  printf 'Fedora verification accepted a locked plugin that is not installed\n' >&2
  exit 1
fi
grep -Fq "Lazy plugin not installed: $withheld_plugin" \
  "$test_root/lazy-missing-verification.log"
mv "$test_root/withheld-plugin" "$bootstrap_data/nvim/lazy/$withheld_plugin"
printf 'PASS: Fedora verification reports a locked plugin the tree is missing\n'

# The preview's server is what a checkout at the locked commit does not prove:
# an install whose build never finished left exactly this tree, and the
# preview opened no browser while every check above passed.
grep -Fq 'Markdown preview server: ' "$test_root/tmux-drift-verification.log"
preview_server="$bootstrap_data/nvim/lazy/markdown-preview.nvim/app/bin/$(bash -c 'source "$1/common/lib/markdown-preview.sh" && markdown_preview_server_name' _ "$repo_root")"
mv "$preview_server" "$test_root/withheld-preview-server"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/preview-missing-verification.log" 2>&1; then
  printf 'Fedora verification accepted a Markdown preview with no server\n' >&2
  exit 1
fi
grep -Fq 'Markdown preview server absent: ' "$test_root/preview-missing-verification.log"
mv "$test_root/withheld-preview-server" "$preview_server"
printf 'PASS: Fedora verification reports a Markdown preview with no server\n'

# The mise section asks a login that is not interactive as well, not only the
# AI verifier: a dnf package of a mise-owned runtime sits in /usr/bin, which
# every login inherits. Before #507 (V4-11) this verifier never asked that
# login; once it did, every real Fedora machine failed it, because python,
# node and tree-sitter are all in /usr/bin there and nothing put mise's shims
# on that login's PATH (real-install run 35924092083). The zsh package's
# .zprofile does now. The shim is what makes the interactive probe pass; the
# directory stands in for /usr/bin, ahead of the fixture's own commands.
if grep -Fq 'runs a copy of' "$test_root/tmux-drift-verification.log"; then
  printf 'Fedora verification could not ask a non-interactive login on a healthy machine:\n' >&2
  grep -F 'runs a copy of' "$test_root/tmux-drift-verification.log" >&2
  exit 1
fi
dnf_shadow="$test_root/dnf-shadow-bin"
node_shim="$bootstrap_data/mise/shims/node"
mkdir -p "$dnf_shadow" "$(dirname "$node_shim")"
cp "$mock_bin/mock-command" "$dnf_shadow/node"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$mock_bin/node" >"$node_shim"
chmod +x "$node_shim"
# The machine as the bootstrap stowed it: .zprofile is linked, so the login
# runs the shim ahead of the dnf copy, and the machine verifies.
if ! "${bootstrap_environment[@]}" "PATH=$dnf_shadow:$mock_bin:$PATH" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/dnf-behind-shims-verification.log" 2>&1; then
  cat "$test_root/dnf-behind-shims-verification.log" >&2
  printf 'Fedora verification failed a dnf node that the login shims shadow\n' >&2
  exit 1
fi
if grep -Fq 'resolves outside mise' "$test_root/dnf-behind-shims-verification.log"; then
  printf 'Fedora verification reported a dnf node that .zprofile puts behind the shims\n' >&2
  exit 1
fi
grep -Fq "$bootstrap_config/zsh/.zprofile -> $(realpath "$repo_root/zsh/.config/zsh/.zprofile")" \
  "$test_root/dnf-behind-shims-verification.log"
printf 'PASS: Fedora verification accepts a dnf runtime that the login shims put mise ahead of\n'

# The same machine with .zprofile not linked, which is every machine stowed
# before the file existed: that login really does run the dnf copy, and both
# the missing link and the copy are reported, the second naming the repair.
mv "$bootstrap_config/zsh/.zprofile" "$test_root/withheld-zprofile"
if "${bootstrap_environment[@]}" "PATH=$dnf_shadow:$mock_bin:$PATH" \
  "$repo_root/platforms/fedora/scripts/verify.sh" \
  >"$test_root/dnf-shadow-verification.log" 2>&1; then
  printf 'Fedora verification accepted a dnf node that a non-interactive login runs\n' >&2
  exit 1
fi
mv "$test_root/withheld-zprofile" "$bootstrap_config/zsh/.zprofile"
grep -Fq "$bootstrap_config/zsh/.zprofile is missing" \
  "$test_root/dnf-shadow-verification.log"
grep -Fq "node resolves outside mise in a login that is not interactive: $dnf_shadow/node" \
  "$test_root/dnf-shadow-verification.log"
grep -Fq 'restow the zsh package so that file is linked' \
  "$test_root/dnf-shadow-verification.log"
# The interactive probe must not be what caught it: the shim wins there.
if grep -Fq 'node resolves outside mise in the configured login PATH' \
  "$test_root/dnf-shadow-verification.log"; then
  printf 'The dnf shadow fixture was caught by the interactive probe, so it proves nothing about the other\n' >&2
  exit 1
fi
rm -r -- "$dnf_shadow" "$node_shim"
printf 'PASS: Fedora verification reports a dnf runtime a non-interactive login runs instead of mise\n'

run_bootstrap --vm-guest
vm_guest_state="$bootstrap_config/dotfiles/vm-guest.conf"
first_vm_guest_state="$(sha256sum "$vm_guest_state")"
run_bootstrap --vm-guest
[[ "$(sha256sum "$vm_guest_state")" == "$first_vm_guest_state" ]]
grep -Fqx 'profile=vm-guest' "$vm_guest_state"
printf 'PASS: the normal bootstrap composes with the VM-guest profile twice\n'

printf 'Bootstrap idempotency and upgrade tests passed.\n'
