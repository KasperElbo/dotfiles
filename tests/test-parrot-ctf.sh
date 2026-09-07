#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

assert_contains() {
  [[ "$1" == *"$2"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$2" "$1" >&2
    exit 1
  }
}

dry_run="$("$repo_root/install.sh" --platform parrot-ctf --dry-run)"
assert_contains "$dry_run" 'Parrot Security Edition CTF VM plan'
assert_contains "$dry_run" 'libvirt default NAT'
assert_contains "$dry_run" 'Existing Parrot/APT catalogue (unchanged)'
assert_contains "$dry_run" 'Host secrets:           Not forwarded or mounted'
assert_contains "$dry_run" 'AI tooling:             Not installed'
assert_contains "$dry_run" 'Fedora/DNF/Terra'

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
stow_log="$test_root/stow.log"
channels="$test_root/virtio-ports"
mkdir -p "$mock_bin" "$config" "$channels"
printf 'ID=parrot\n' >"$test_root/os-release"
printf '/bin/bash\n' >"$shell_state"
touch "$channels/org.qemu.guest_agent.0" "$channels/com.redhat.spice.0"

cat >"$mock_bin/apt-get" <<'EOF'
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
cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$COMMAND_LOG"
printf '%s\n' "$2" >"$SHELL_STATE"
EOF
cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
"$@"
EOF
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -un ]] && printf 'parrot-test\n' || /usr/bin/id "$@"
EOF
cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
printf 'parrot-test:x:1000:1000:Parrot Test:/home/parrot-test:%s\n' "$(<"$SHELL_STATE")"
EOF
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
  if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
cat >"$output" <<'INSTALLER'
#!/usr/bin/env sh
mkdir -p "$(dirname "$MISE_INSTALL_PATH")"
printf '#!/usr/bin/env sh\nexit 0\n' >"$MISE_INSTALL_PATH"
chmod +x "$MISE_INSTALL_PATH"
INSTALLER
EOF
cat >"$mock_bin/stow" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >>"$STOW_LOG"
EOF
chmod +x "$mock_bin"/*

test_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "PATH=$mock_bin:/usr/bin:/bin"
  "OS_RELEASE_FILE=$test_root/os-release"
  "COMMAND_LOG=$command_log"
  "SHELL_STATE=$shell_state"
  "STOW_LOG=$stow_log"
  "QEMU_AGENT_CHANNEL=$channels/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$channels/com.redhat.spice.0"
)

"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" >/dev/null
first_mise="$(sha256sum "$home/.local/bin/mise")"
"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh" >/dev/null
[[ "$(sha256sum "$home/.local/bin/mise")" == "$first_mise" ]]
grep -Fq 'sudo apt-get update' "$command_log"
grep -Fq 'apt-get install -y --no-install-recommends bat build-essential' "$command_log"
grep -Fq 'starship' "$command_log"
grep -Fqx '/bin/zsh' "$shell_state"

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
grep -Fq 'systemctl enable --now qemu-guest-agent.service' "$command_log"

"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/stow.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/stow.sh" >/dev/null
for package in bat bin fzf git lazygit nvim-lazyvim starship tmux zsh \
  command-shims mise-ctf zsh-platform; do
  grep -Fqx "$package" "$stow_log"
done
if grep -Eq '^(ghostty|mise|sway|waybar|theme-hooks)$' "$stow_log"; then
  printf 'Parrot CTF profile deployed a workstation-only Stow package.\n' >&2
  exit 1
fi

if grep -Eiq 'metasploit|nmap|sqlmap|burpsuite|parrot-tools' \
  "$repo_root/platforms/parrot-ctf/scripts/install-system.sh"; then
  printf 'Parrot profile contains a duplicated offensive-tool catalogue.\n' >&2
  exit 1
fi

printf 'ID=fedora\n' >"$test_root/not-parrot"
if OS_RELEASE_FILE="$test_root/not-parrot" PATH="$mock_bin:/usr/bin:/bin" \
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
