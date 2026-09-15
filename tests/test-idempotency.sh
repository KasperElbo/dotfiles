#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
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
debugger_path="$test_root/easydotnet/tools/netcoredbg/linux-x64/netcoredbg"
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
  tmux wl-clipboard xdg-utils zoxide zsh zsh-autosuggestions \
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

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  '-q terra-release' | '-q qemu-guest-agent' | '-q spice-vdagent' | '-q xclip' | '-q openssh-clients') exit 0 ;;
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

chmod +x \
  "$mock_bin/mock-command" \
  "$mock_bin/rpm" \
  "$mock_bin/id" \
  "$mock_bin/getent" \
  "$stub_root/handlers/sudo"

mock_commands=(
  ast-grep
  bat
  delta
  dnf
  dotnet
  dotnet-easydotnet
  eza
  fd
  fzf
  gh
  ghostty
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

rm -- "$mock_bin/zsh"
cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'printf "%s\\n" "$PATH"'* ]]; then
  printf '%s\n' "$XDG_DATA_HOME/mise/shims:$HOME/.local/bin:$PATH"
fi
exit 0
EOF
chmod +x "$mock_bin/zsh"

rm -- "$mock_bin/dotnet-easydotnet"
cat >"$mock_bin/dotnet-easydotnet" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == healthcheck ]]; then
  printf '[{"type":"ok","name":"debugger.engine","value":"netcoredbg"},{"type":"ok","name":"debugger.source","value":"bundled"},{"type":"ok","name":"debugger.platform","value":"linux-x64"},{"type":"ok","name":"debugger.path","value":"%s"},{"type":"ok","name":"debugger.version","value":"NET Core debugger test version"}]\n' \
    "$MOCK_EASY_DOTNET_DEBUGGER"
fi
EOF
chmod +x "$mock_bin/dotnet-easydotnet"

cat >"$mock_bin/mise" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == exec && "${2:-}" == -- ]]; then
  shift 2
  exec "$@"
elif [[ "${1:-}" == which && -n "${2:-}" ]]; then
  command -v "$2"
  exit $?
fi
exit 0
EOF
chmod +x "$mock_bin/mise"

cat >"$mock_bin/nvim" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == '+Lazy! restore mason.nvim' ]]; then
    mkdir -p "$XDG_DATA_HOME/nvim/lazy/mason.nvim"
  fi

  if [[ "$argument" == */common/bootstrap-mason.lua ]]; then
    mkdir -p "$XDG_DATA_HOME/nvim/mason/bin"
    for target in $DOTFILES_MASON_PACKAGES; do
      # Mason stores a package under its name whether or not the request
      # carried an "@version" pin.
      package="${target%%@*}"
      mkdir -p "$XDG_DATA_HOME/nvim/mason/packages/$package"
      if [[ "$package" == tree-sitter-cli ]]; then
        cat >"$XDG_DATA_HOME/nvim/mason/bin/tree-sitter" <<'TREEEOF'
#!/usr/bin/env bash
exit 0
TREEEOF
        chmod +x "$XDG_DATA_HOME/nvim/mason/bin/tree-sitter"
      fi
    done
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

run_bootstrap --vm-guest
vm_guest_state="$bootstrap_config/dotfiles/vm-guest.conf"
first_vm_guest_state="$(sha256sum "$vm_guest_state")"
run_bootstrap --vm-guest
[[ "$(sha256sum "$vm_guest_state")" == "$first_vm_guest_state" ]]
grep -Fqx 'profile=vm-guest' "$vm_guest_state"
printf 'PASS: the normal bootstrap composes with the VM-guest profile twice\n'

printf 'Bootstrap idempotency and upgrade tests passed.\n'
