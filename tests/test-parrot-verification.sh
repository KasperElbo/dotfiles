#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

home="$test_root/home"
config="$home/.config"
data="$home/.local/share"
local_bin="$home/.local/bin"
mock_bin="$test_root/bin"
channels="$test_root/virtio-ports"
nvim_install="$data/mise/installs/nvim/0.12.5/bin/nvim"
mkdir -p \
  "$config/dotfiles" \
  "$config/mise" \
  "$config/nvim/profiles/parrot-ctf" \
  "$config/starship" \
  "$data/mise/shims" \
  "$data/nvim/mason/packages" \
  "$local_bin" \
  "$mock_bin" \
  "$channels" \
  "$(dirname "$nvim_install")"

printf 'ID=parrot\n' >"$test_root/os-release"
touch "$channels/org.qemu.guest_agent.0" "$channels/com.redhat.spice.0"

cat >"$nvim_install" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'NVIM v0.12.5\n'
fi
exit 0
EOF
chmod +x "$nvim_install"
ln -s "$nvim_install" "$data/mise/shims/nvim"

cat >"$local_bin/mise" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  which)
    [[ "$2" == nvim ]] || exit 1
    printf '%s\n' "$MOCK_NVIM"
    ;;
  exec)
    shift
    [[ "$1" == -- ]] && shift
    if [[ "$1" == uv ]]; then
      printf 'uv 0.9.0\n'
      exit 0
    fi
    exec "$MOCK_NVIM" "${@:2}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$local_bin/mise"

cat >"$mock_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -W) printf 'install ok installed' ;;
  -S) printf 'parrot-mock: %s\n' "${2:-/usr/bin/mock}" ;;
  *) exit 1 ;;
esac
EOF
cat >"$mock_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
printf 'kvm\n'
EOF
cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/starship" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == prompt ]]
EOF
chmod +x \
  "$mock_bin/dpkg-query" \
  "$mock_bin/systemd-detect-virt" \
  "$mock_bin/systemctl" \
  "$mock_bin/starship"

generic_commands=(
  apt-get bat batcat eza fd fdfind fzf gh lazygit pipx python python3 rg sqlite3
  stow tmux xclip xxd zoxide zsh nmap hashcat john sqlmap gobuster ffuf hydra
)
for command_name in "${generic_commands[@]}"; do
  ln -s /usr/bin/true "$mock_bin/$command_name"
done
ln -s /usr/bin/jq "$mock_bin/jq"

cat >"$mock_bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${3:-}" == rev-parse && "${4:-}" == HEAD ]]; then
  plugin_name="$(basename "$2")"
  jq -r --arg plugin "$plugin_name" '.[$plugin].commit // empty' "$MOCK_LAZY_LOCK"
  exit 0
fi
exit 0
EOF
chmod +x "$mock_bin/git"

ln -s "$repo_root/platforms/parrot-ctf/stow/mise-ctf/.config/mise/config.toml" \
  "$config/mise/config.toml"
ln -s "$repo_root/nvim-lazyvim/.config/nvim/init.lua" "$config/nvim/init.lua"
ln -s "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt" \
  "$config/nvim/profiles/parrot-ctf/mason-packages.txt"
ln -s "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/lazy-lock.json" \
  "$config/nvim/profiles/parrot-ctf/lazy-lock.json"
ln -s "$repo_root/starship/.config/starship/catppuccin-macchiato.toml" \
  "$config/starship/catppuccin-macchiato.toml"
printf 'macchiato\n' >"$config/dotfiles/theme"
printf 'parrot-ctf\n' >"$test_root/neovim-profile-source"
ln -s "$test_root/neovim-profile-source" "$config/dotfiles/neovim-profile"
cat >"$config/dotfiles/parrot-ctf.conf" <<'EOF'
profile=parrot-ctf
hypervisor=kvm
network=host-managed-default-nat
guest_agent=qemu-guest-agent
host_secrets=not-shared
security_tools=parrot-apt-owned
EOF

ln -s "$repo_root/zsh/.zshenv" "$home/.zshenv"
mkdir -p "$config/zsh" "$config/git"
ln -s "$repo_root/zsh/.config/zsh/.zshrc" "$config/zsh/.zshrc"
ln -s "$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform.zsh" \
  "$config/zsh/platform.zsh"
ln -s "$repo_root/git/.config/git/config" "$config/git/config"
ln -s "$repo_root/tmux/.tmux.conf" "$home/.tmux.conf"
ln -s "$repo_root/platforms/parrot-ctf/stow/command-shims/.local/bin/bat" "$local_bin/bat"
ln -s "$repo_root/platforms/parrot-ctf/stow/command-shims/.local/bin/fd" "$local_bin/fd"

while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  mkdir -p "$data/nvim/mason/packages/$package"
done <"$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"

while IFS= read -r plugin_name; do
  mkdir -p "$data/nvim/lazy/$plugin_name"
done < <(jq -r 'keys[]' "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/lazy-lock.json")

verify_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "XDG_DATA_HOME=$data"
  "PATH=$mock_bin:/usr/bin:/bin"
  "MISE_DATA_DIR=$data/mise"
  "MOCK_NVIM=$nvim_install"
  "MOCK_LAZY_LOCK=$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/lazy-lock.json"
  "OS_RELEASE_FILE=$test_root/os-release"
  "QEMU_AGENT_CHANNEL=$channels/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$channels/com.redhat.spice.0"
)

verification_output="$(
  "${verify_environment[@]}" \
    "$repo_root/platforms/parrot-ctf/scripts/verify.sh" 2>&1
)"
grep -Fq 'Parrot CTF verification passed.' <<<"$verification_output"
grep -Fq 'python3 remains Parrot/APT-owned' <<<"$verification_output"
grep -Fq 'Neovim 0.12.5 satisfies the >= 0.12 baseline' <<<"$verification_output"
grep -Fq 'Mason inventory exactly matches the reduced Parrot profile' <<<"$verification_output"
grep -Fq 'Reduced LazyVim plugins match the Parrot lockfile' <<<"$verification_output"

mkdir -p "$data/nvim/mason/packages/roslyn"
if "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/unexpected-mason.log" 2>&1; then
  printf 'Parrot verification accepted an unexpected Mason package.\n' >&2
  exit 1
fi
grep -Fq 'Mason inventory mismatch' "$test_root/unexpected-mason.log"
grep -Fq 'roslyn' "$test_root/unexpected-mason.log"
rmdir "$data/nvim/mason/packages/roslyn"

ln -s /usr/bin/true "$local_bin/nmap"
if "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/shadowed-tool.log" 2>&1; then
  printf 'Parrot verification accepted a user security-tool shim.\n' >&2
  exit 1
fi
grep -Fq 'Protected security-tool shim present: nmap' "$test_root/shadowed-tool.log"
grep -Fq 'command -v:' "$test_root/shadowed-tool.log"

printf 'Parrot clean-install and PATH ownership verification tests passed.\n'
