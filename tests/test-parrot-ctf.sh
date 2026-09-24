#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_isolate_path gzip python3 rg sha256sum tar zsh
test_new_root
test_root="$TEST_ROOT"

dry_run="$("$repo_root/install.sh" --platform parrot-ctf --dry-run)"
assert_contains "$dry_run" 'Parrot Security Edition CTF VM plan'
assert_contains "$dry_run" 'libvirt default NAT'
assert_contains "$dry_run" 'Existing Parrot/APT catalogue (unchanged)'
assert_contains "$dry_run" 'Host secrets:        Not forwarded or mounted'
assert_contains "$dry_run" 'AI tooling:          Not installed'
assert_contains "$dry_run" 'mise owns uv and pinned Neovim 0.12.5 only'
assert_contains "$dry_run" 'reduced LazyVim/Mason inventory'
assert_contains "$dry_run" 'Fedora/DNF/Terra'

theme_home="$test_root/theme-home"
mkdir -p "$theme_home/.config/dotfiles"
fresh_theme="$(HOME="$theme_home" XDG_CONFIG_HOME="$theme_home/.config" \
  "$repo_root/install.sh" --platform parrot-ctf --dry-run)"
assert_contains "$fresh_theme" 'Catppuccin flavour:  macchiato'
assert_contains "$fresh_theme" 'Flavour source:      default — first-install default'
printf 'mocha\n' >"$theme_home/.config/dotfiles/theme"
persisted_theme="$(HOME="$theme_home" XDG_CONFIG_HOME="$theme_home/.config" \
  "$repo_root/install.sh" --platform parrot-ctf --dry-run)"
assert_contains "$persisted_theme" 'Catppuccin flavour:  mocha'
assert_contains "$persisted_theme" 'Flavour source:      existing — existing choice on this machine'
explicit_theme="$(HOME="$theme_home" XDG_CONFIG_HOME="$theme_home/.config" \
  "$repo_root/install.sh" --platform parrot-ctf --dry-run --theme latte)"
assert_contains "$explicit_theme" 'Catppuccin flavour:  latte'
assert_contains "$explicit_theme" 'Flavour source:      explicit — explicit --theme on this run'

if "$repo_root/install.sh" --platform parrot-ctf --dry-run --vm-host \
  >"$test_root/fedora-option.log" 2>&1; then
  printf 'Parrot profile unexpectedly accepted a Fedora VM-host option.\n' >&2
  exit 1
fi
grep -Fq 'Unknown option for parrot-ctf: --vm-host' "$test_root/fedora-option.log"

mock_bin="$test_root/bin"
home="$test_root/home"
config="$home/.config"
command_log="$test_root/commands.log"
shell_state="$test_root/login-shell"
shells_file="$test_root/shells"
stow_log="$test_root/stow.log"
channels="$test_root/virtio-ports"
mkdir -p "$mock_bin" "$config" "$channels"
printf 'ID=parrot\n' >"$test_root/os-release"
printf '/bin/bash\n' >"$shell_state"
# The isolated PATH decides which Zsh the installer resolves and registers.
zsh_path="$(command -v zsh)"
printf '%s\n' "$zsh_path" >"$shells_file"
touch "$channels/org.qemu.guest_agent.0" "$channels/com.redhat.spice.0"

test_stub_init "$test_root"
for command_name in apt-get sudo systemctl; do
  test_stub_install "$test_root" "$command_name"
done
parrot_packages=(
  bat build-essential ca-certificates curl eza fd-find fontconfig fzf gh git
  git-delta jq konsole lazygit pipx python-is-python3 python3 python3-dev
  python3-pip python3-venv ripgrep shellcheck sqlite3 starship stow tmux unzip
  xclip xdg-utils xxd xz-utils zoxide zsh zsh-autosuggestions
  zsh-syntax-highlighting
)
test_stub_allow "$test_root" apt-get update
test_stub_allow "$test_root" apt-get install -y --no-install-recommends \
  "${parrot_packages[@]}"
test_stub_allow "$test_root" apt-get install -y --no-install-recommends \
  qemu-guest-agent spice-vdagent
test_stub_allow "$test_root" sudo apt-get update
test_stub_allow "$test_root" sudo apt-get install -y --no-install-recommends \
  "${parrot_packages[@]}"
test_stub_allow "$test_root" sudo apt-get install -y --no-install-recommends \
  qemu-guest-agent spice-vdagent
test_stub_allow "$test_root" sudo usermod --shell "$zsh_path" parrot-test
test_stub_allow "$test_root" sudo systemctl start qemu-guest-agent.service
test_stub_allow "$test_root" sudo systemctl start spice-vdagentd.socket
test_stub_allow "$test_root" systemctl start qemu-guest-agent.service
test_stub_allow "$test_root" systemctl start spice-vdagentd.socket

cat >"$test_root/handlers/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed'
EOF
cat >"$mock_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_VM_TYPE:-kvm}"
[[ "${MOCK_VM_TYPE:-kvm}" != none ]]
EOF
cat >"$test_root/handlers/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$COMMAND_LOG"
printf '%s\n' "$2" >"$SHELL_STATE"
EOF
cat >"$test_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
exec "$@"
EOF
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) [[ "${MOCK_ROOT:-false}" != true ]] && printf '1000\n' || printf '0\n' ;;
  -un) printf 'parrot-test\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
printf 'parrot-test:x:1000:1000:Parrot Test:/home/parrot-test:%s\n' "$(<"$SHELL_STATE")"
EOF
# mise comes from a pinned release archive (#504): the stub serves whatever
# BOOTSTRAP_SERVE_DIR holds under the requested name, and nothing else.
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
while (($#)); do
  if [[ "$1" == --output ]]; then output="$2"; shift 2
  elif [[ "$1" == https://* ]]; then url="$1"; shift
  else shift; fi
done
if [[ "$url" == https://dotfiles-test.invalid/* ]]; then
  cp -- "$BOOTSTRAP_SERVE_DIR/${url##*/}" "$output"
  exit 0
fi
printf 'strict curl fixture rejected unexpected URL: %s\n' "$url" >&2
exit 96
EOF
cat >"$mock_bin/stow" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >>"$STOW_LOG"
EOF
cat >"$mock_bin/xxd" <<'EOF'
#!/usr/bin/env python3
import sys

data = sys.stdin.buffer.read()
if "-r" in sys.argv:
    sys.stdout.buffer.write(bytes.fromhex(data.decode().strip()))
else:
    sys.stdout.write(data.hex() + "\n")
EOF
chmod +x "$mock_bin"/* "$test_root/handlers"/*

test_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "PATH=$mock_bin:$PATH"
  "OS_RELEASE_FILE=$test_root/os-release"
  "COMMAND_LOG=$command_log"
  "SHELL_STATE=$shell_state"
  "SHELLS_FILE=$shells_file"
  "STOW_LOG=$stow_log"
  "QEMU_AGENT_CHANNEL=$channels/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$channels/com.redhat.spice.0"
  "DOTFILES_TEST_BOOTSTRAP_ARCHIVES=$test_root/pinned-archives"
  "BOOTSTRAP_SERVE_DIR=$test_root/pinned-archives"
)
test_bootstrap_archives "$test_root/pinned-archives" pinned
test_bootstrap_archives "$test_root/tampered-archives" tampered

"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" >/dev/null
first_mise="$(sha256sum "$home/.local/bin/mise")"
"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" >/dev/null
[[ "$(sha256sum "$home/.local/bin/mise")" == "$first_mise" ]]
assert_eq 'mise pinned' "$("$home/.local/bin/mise")" 'mise must come from the pinned archive'

# A download that differs from the pin is refused before it is unpacked.
tampered_home="$test_root/tampered-home"
mkdir -p "$tampered_home"
if "${test_environment[@]}" HOME="$tampered_home" \
  BOOTSTRAP_SERVE_DIR="$test_root/tampered-archives" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" \
  >"$test_root/tampered.log" 2>&1; then
  _test_die 'Parrot installed mise from an archive that does not match its pin'
fi
assert_file_contains "$test_root/tampered.log" 'SHA-256 mismatch for the pinned mise release'
assert_path_missing "$tampered_home/.local/bin/mise"
printf 'PASS: Parrot installs mise from the pinned archive and refuses one that differs\n'
grep -Fq 'sudo apt-get update' "$command_log"
grep -Fq 'apt-get install -y --no-install-recommends bat build-essential' "$command_log"
grep -Fq 'starship' "$command_log"
grep -Fq 'xclip xdg-utils xxd' "$command_log"
if grep -Eq '(^| )neovim( |$)' "$command_log"; then
  printf 'Parrot APT package list still owns Neovim.\n' >&2
  exit 1
fi
grep -Fqx "$zsh_path" "$shell_state"

usermod_count="$(grep -Fc 'sudo usermod --shell' "$command_log")"
if "${test_environment[@]}" env MOCK_ROOT=true \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" \
  >"$test_root/root-shell.log" 2>&1; then
  printf 'Parrot installer attempted to support a root invocation.\n' >&2
  exit 1
fi
grep -Fq "Refusing to change root's login shell" "$test_root/root-shell.log"
[[ "$(grep -Fc 'sudo usermod --shell' "$command_log")" == "$usermod_count" ]]

printf '/bin/bash\n' >"$test_root/unregistered-shells"
if "${test_environment[@]}" env SHELLS_FILE="$test_root/unregistered-shells" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" \
  >"$test_root/unregistered-shell.log" 2>&1; then
  printf 'Parrot installer accepted an unregistered login shell.\n' >&2
  exit 1
fi
grep -Fq 'is not registered' "$test_root/unregistered-shell.log"

"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-guest-integration.sh" >/dev/null
state_file="$config/dotfiles/parrot-ctf.conf"
first_state="$(sha256sum "$state_file")"
"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-guest-integration.sh" >/dev/null
[[ "$(sha256sum "$state_file")" == "$first_state" ]]
grep -Fxq 'network=host-managed-default-nat' "$state_file"
grep -Fxq 'host_secrets=not-shared' "$state_file"
grep -Fxq 'security_tools=parrot-apt-owned' "$state_file"
grep -Fq 'systemctl start qemu-guest-agent.service' "$command_log"
if grep -Fq 'systemctl enable --now qemu-guest-agent.service' "$command_log"; then
  printf 'Parrot attempted to enable the static qemu-guest-agent unit.\n' >&2
  exit 1
fi

"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/stow.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/stow.sh" >/dev/null
for package in bat bin fzf git lazygit nvim-lazyvim starship tmux zsh \
  command-shims mise-ctf neovim-profile zsh-platform; do
  grep -Fqx "$package" "$stow_log"
done
if grep -Eq '^(ghostty|mise|sway|waybar|theme-hooks)$' "$stow_log"; then
  printf 'Parrot CTF profile deployed a workstation-only Stow package.\n' >&2
  exit 1
fi

mise_manifest="$repo_root/platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml"
grep -Fqx 'nvim = "github:neovim/neovim"' "$mise_manifest"
grep -Fq 'nvim = { version = "0.12.5"' "$mise_manifest"
if grep -Eq '^[[:space:]]*python[[:space:]]*=' "$mise_manifest"; then
  printf 'Parrot mise manifest unexpectedly manages Python.\n' >&2
  exit 1
fi

# A glob tracks whatever the Starship generator currently produces; a missing
# file must never read as "symbol not present".
starship_configs=("$repo_root"/starship/.config/starship/*.toml)
if [[ ! -f "${starship_configs[0]}" ]]; then
  printf 'No generated Starship configurations found to check.\n' >&2
  exit 1
fi
for config in "${starship_configs[@]}"; do
  if grep -Fq 'AOSC =' "$config"; then
    printf 'Unsupported AOSC Starship symbol remains in %s.\n' "$config" >&2
    exit 1
  fi
done

parrot_zsh="$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh"
parrot_env="$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform-env.zsh"
path_output="$(PATH="/usr/bin:/bin:/usr/bin" zsh -f -c "source '$parrot_env'; source '$parrot_env'; print -l -- \$path")"
for expected_path in /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
  [[ "$(grep -Fxc "$expected_path" <<<"$path_output")" == 1 ]]
done
shell_output="$(
  PATH="$mock_bin:$PATH" zsh -f -c \
    "source '$parrot_zsh'; alias x-copy; hex-encode CTF; hex-decode 435446; rot13 CTF"
)"
assert_contains "$shell_output" "x-copy='xclip -selection clipboard'"
assert_contains "$shell_output" '4354460a'
assert_contains "$shell_output" 'CTF'
assert_contains "$shell_output" 'PGS'

unmatched_glob="$(
  cd "$test_root"
  zsh -f -c "source '$parrot_zsh'; print -r -- https://target.invalid/FUZZ?id=* 'user?' 'hash[a-f]'"
)"
[[ "$unmatched_glob" == 'https://target.invalid/FUZZ?id=* user? hash[a-f]' ]] || {
  printf 'Parrot unmatched glob did not pass through literally: %s\n' "$unmatched_glob" >&2
  exit 1
}
mkdir -p "$test_root/glob"
touch "$test_root/glob/one.txt" "$test_root/glob/two.txt"
matched_glob="$(
  cd "$test_root/glob"
  zsh -f -c "source '$parrot_zsh'; print -l -- *.txt"
)"
[[ "$matched_glob" == $'one.txt\ntwo.txt' ]] || {
  printf 'Parrot normal filename globbing was disabled: %s\n' "$matched_glob" >&2
  exit 1
}

fedora_zsh="$repo_root/platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh"
fedora_state="$test_root/fedora-state"
mkdir -p "$fedora_state/dotfiles"
if XDG_CONFIG_HOME="$fedora_state" zsh -f -c "source '$fedora_zsh'; alias x-copy" \
  >"$test_root/native-fedora-alias.log" 2>&1; then
  printf 'Native Fedora unexpectedly received the VM-only x-copy alias.\n' >&2
  exit 1
fi
printf 'profile=vm-guest\n' >"$fedora_state/dotfiles/vm-guest.conf"
fedora_alias="$(XDG_CONFIG_HOME="$fedora_state" zsh -f -c "source '$fedora_zsh'; alias x-copy")"
[[ "$fedora_alias" == "x-copy='xclip -selection clipboard'" ]]
if rg -q 'alias x-copy=' "$repo_root/platforms/fedora-wsl"; then
  printf 'Fedora WSL unexpectedly received the VM-only x-copy alias.\n' >&2
  exit 1
fi

if code_grep -Eiq 'metasploit|nmap|sqlmap|burpsuite|parrot-tools' \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh"; then
  printf 'Parrot profile contains a duplicated offensive-tool catalogue.\n' >&2
  exit 1
fi

printf 'ID=fedora\n' >"$test_root/not-parrot"
if OS_RELEASE_FILE="$test_root/not-parrot" PATH="$mock_bin:$PATH" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" \
  >"$test_root/not-parrot.log" 2>&1; then
  printf 'Parrot package installer accepted Fedora.\n' >&2
  exit 1
fi
grep -Fq 'supports Parrot Security Edition only' "$test_root/not-parrot.log"

before_rejection="$(sha256sum "$command_log")"
if "${test_environment[@]}" env MOCK_VM_TYPE=none \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" \
  >"$test_root/bare-metal.log" 2>&1; then
  printf 'Parrot CTF installer accepted bare metal.\n' >&2
  exit 1
fi
grep -Fq 'must run inside a detected virtual machine' "$test_root/bare-metal.log"
[[ "$(sha256sum "$command_log")" == "$before_rejection" ]]

printf 'Parrot CTF composition, isolation, and idempotency tests passed.\n'
