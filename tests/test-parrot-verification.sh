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

# The pinned font version is read from the installer rather than repeated here,
# so bumping the pin cannot leave this suite building its fixture under the
# previous version's directory while the verifier looks under the new one.
font_pin="$(sed -n 's/^font_version="\([0-9][0-9.]*\)"$/\1/p' \
  "$repo_root/platforms/parrot-ctf/scripts/install-terminal.sh")"
[[ -n "$font_pin" ]] || {
  printf 'could not read the Hack Nerd Font pin from the Parrot terminal installer\n' >&2
  exit 1
}

mkdir -p \
  "$config/dotfiles" \
  "$config/mise" \
  "$config/nvim/profiles/parrot-ctf" \
  "$config/starship" \
  "$config/bat/themes" \
  "$data/fonts/HackNerdFont/$font_pin" \
  "$data/konsole" \
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
[[ "${1:-}" == prompt || "${1:-}" == --version ]]
EOF
cat >"$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -un) printf 'parrot-test\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
cat >"$mock_bin/getent" <<'EOF'
#!/usr/bin/env bash
printf 'parrot-test:x:1000:1000:Parrot Test:%s:%s\n' "$HOME" "$MOCK_ZSH"
EOF
cat >"$mock_bin/fc-match" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *family*) printf 'Hack Nerd Font Mono\n' ;;
  *file*) printf '%s\n' "$MOCK_FONT" ;;
esac
EOF
cat >"$mock_bin/fc-query" <<'EOF'
#!/usr/bin/env bash
printf '20-7e e0b0-e0c8 f000-f381 f0001-f1af0\n'
EOF
cat >"$mock_bin/bat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --list-themes ]]; then
  printf 'Catppuccin Latte\nCatppuccin Frappe\nCatppuccin Macchiato\nCatppuccin Mocha\n'
fi
EOF
cat >"$mock_bin/batcat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --list-themes ]]; then
  printf 'Catppuccin Latte\nCatppuccin Frappe\nCatppuccin Macchiato\nCatppuccin Mocha\n'
fi
EOF
cat >"$mock_bin/ip" <<'EOF'
#!/usr/bin/env bash
printf 'default via 192.0.2.1 dev enp1s0\n'
EOF
cat >"$mock_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'ext4 / /dev/vda2\n'
EOF
chmod +x \
  "$mock_bin/dpkg-query" \
  "$mock_bin/bat" \
  "$mock_bin/batcat" \
  "$mock_bin/fc-match" \
  "$mock_bin/fc-query" \
  "$mock_bin/getent" \
  "$mock_bin/id" \
  "$mock_bin/ip" \
  "$mock_bin/findmnt" \
  "$mock_bin/systemd-detect-virt" \
  "$mock_bin/systemctl" \
  "$mock_bin/starship"

generic_commands=(
  apt-get eza fd fdfind fzf gh lazygit pipx python python3 rg sqlite3
  stow tmux xclip xxd zoxide zsh nmap hashcat john sqlmap gobuster ffuf hydra
)
for command_name in "${generic_commands[@]}"; do
  ln -s /usr/bin/true "$mock_bin/$command_name"
done
ln -s /usr/bin/jq "$mock_bin/jq"

cat >"$mock_bin/git" <<'EOF'
#!/usr/bin/env bash
# The Catppuccin tmux fixture is a real repository; only the Lazy plugin
# checkouts are simulated from the lockfile.
if [[ "${1:-}" == -C && "${2:-}" == "$MOCK_TMUX_PLUGIN" ]]; then
  exec /usr/bin/git "$@"
fi
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
ln -s "$repo_root/platforms/parrot-ctf/stow/neovim-profile/.config/dotfiles/neovim-profile" \
  "$config/dotfiles/neovim-profile"
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
ln -s "$repo_root/platforms/parrot-ctf/stow/zsh-platform/.config/zsh/platform-env.zsh" \
  "$config/zsh/platform-env.zsh"
ln -s "$repo_root/git/.config/git/config" "$config/git/config"
ln -s "$repo_root/tmux/.tmux.conf" "$home/.tmux.conf"
ln -s "$repo_root/platforms/parrot-ctf/stow/command-shims/.local/bin/bat" "$local_bin/bat"
ln -s "$repo_root/platforms/parrot-ctf/stow/command-shims/.local/bin/fd" "$local_bin/fd"
printf 'font fixture\n' >"$data/fonts/HackNerdFont/$font_pin/HackNerdFontMono-Regular.ttf"
cat >"$data/konsole/Dotfiles-Parrot-CTF.profile" <<'EOF'
[General]
Name=Dotfiles Parrot CTF
Parent=FALLBACK/
[Appearance]
Font=Hack Nerd Font Mono,10,-1,5,50,0,0,0,0,0
EOF
printf '[Desktop Entry]\nDefaultProfile=Dotfiles-Parrot-CTF.profile\n' >"$config/konsolerc"

# A package directory is not an installation: Mason promotes the staged files,
# links the executables and writes mason-receipt.json last, so a directory is
# evidence that an install was started and never that one finished. The fixture
# leaves behind what a finished install leaves, and the cases further down
# damage it one way at a time.
mason_mock_install="$repo_root/tests/support/mason-mock-install.sh"
parrot_mason_root="$data/nvim/mason"
mapfile -t parrot_mason_packages < <(
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/mason-packages.txt"
)
((${#parrot_mason_packages[@]} > 0)) || {
  printf 'The reduced Parrot Mason inventory is empty, so these cases prove nothing\n' >&2
  exit 1
}
"$mason_mock_install" --pins "$repo_root/common/mason-package-versions.txt" \
  "$parrot_mason_root" "${parrot_mason_packages[@]}"

while IFS= read -r plugin_name; do
  mkdir -p "$data/nvim/lazy/$plugin_name"
done < <(jq -r 'keys[]' "$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/lazy-lock.json")

# The pinned Catppuccin tmux checkout, as common/install-tmux-theme.sh leaves it.
tmux_plugin="$data/tmux/plugins/catppuccin"
tmux_pin="$(sed -n 's/^version="\(v[0-9][0-9.]*\)"$/\1/p' "$repo_root/common/install-tmux-theme.sh")"
mkdir -p "$tmux_plugin"
/usr/bin/git -C "$tmux_plugin" init -q
printf '# theme\n' >"$tmux_plugin/catppuccin.tmux"
/usr/bin/git -C "$tmux_plugin" add catppuccin.tmux
/usr/bin/git -C "$tmux_plugin" -c user.name=Test -c user.email=test@example.invalid \
  commit -qm theme
/usr/bin/git -C "$tmux_plugin" tag "$tmux_pin"

# Install-time state the verifier reads and never writes (issue #345).
parrot_mise_context="$home/.local/state/dotfiles/mise-context"
mkdir -p "$parrot_mise_context"

verify_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "XDG_DATA_HOME=$data"
  "XDG_STATE_HOME=$home/.local/state"
  "PATH=$mock_bin:/usr/bin:/bin"
  "MISE_DATA_DIR=$data/mise"
  "MOCK_NVIM=$nvim_install"
  "MOCK_LAZY_LOCK=$repo_root/nvim-lazyvim/.config/nvim/profiles/parrot-ctf/lazy-lock.json"
  "MOCK_TMUX_PLUGIN=$tmux_plugin"
  "MOCK_ZSH=$mock_bin/zsh"
  "MOCK_FONT=$data/fonts/HackNerdFont/$font_pin/HackNerdFontMono-Regular.ttf"
  "SHELL=$mock_bin/zsh"
  "OS_RELEASE_FILE=$test_root/os-release"
  "QEMU_AGENT_CHANNEL=$channels/org.qemu.guest_agent.0"
  "SPICE_AGENT_CHANNEL=$channels/com.redhat.spice.0"
)

verification_output="$(
  "${verify_environment[@]}" \
    "$repo_root/platforms/parrot-ctf/scripts/verify.sh" 2>&1
)"
grep -Fq 'Parrot CTF verification passed.' <<<"$verification_output"
grep -Fq "Catppuccin tmux is at the pinned $tmux_pin" <<<"$verification_output"

# The APT packages the verifier checks are exactly the Parrot base and
# vm-guest rows of the manifest, minus mise, the one declared package an
# upstream installer rather than APT provides.
expected_apt_packages() {
  awk -F '\t' '$2 == "parrot-ctf" && ($1 == "base" || $1 == "vm-guest") { print $9 }' "$1" |
    tr ',' '\n' | grep -vx -e mise -e - | sort -u
}
checked_apt_packages() {
  sed -n 's/^.* \([^ ]*\) is APT-owned$/\1/p' <<<"$1" | sort -u
}
compare_apt_packages() {
  local expected="$1" checked="$2" unchecked undeclared
  unchecked="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$checked"))"
  undeclared="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$checked"))"
  [[ -n "$unchecked$undeclared" ]] || return 0
  printf 'Parrot verifier packages differ from config/capabilities.tsv; unchecked: %s; undeclared: %s\n' \
    "${unchecked//$'\n'/ }" "${undeclared//$'\n'/ }" >&2
  return 1
}

registry_packages="$(expected_apt_packages "$repo_root/config/capabilities.tsv")"
[[ "$registry_packages" == *build-essential* && "$registry_packages" == *qemu-guest-agent* ]]
compare_apt_packages "$registry_packages" "$(checked_apt_packages "$verification_output")"

# Negative control: the verifier really reads the row. Drop one package from a
# scratch copy of the manifest and the checked set no longer matches the
# registry, naming the package that went unchecked.
scratch_manifest="$test_root/capabilities.tsv"
awk -F '\t' -v OFS='\t' '$1 == "base" && $2 == "parrot-ctf" { sub(/(^|,)curl,/, ",", $9); sub(/^,/, "", $9) } { print }' \
  "$repo_root/config/capabilities.tsv" >"$scratch_manifest"
scratch_output="$(
  "${verify_environment[@]}" "CAPABILITY_MANIFEST=$scratch_manifest" \
    "$repo_root/platforms/parrot-ctf/scripts/verify.sh" 2>&1
)" || true
if compare_apt_packages "$registry_packages" "$(checked_apt_packages "$scratch_output")" \
  2>"$test_root/package-drift.log"; then
  printf 'A package removed from the manifest row was still checked by the verifier.\n' >&2
  exit 1
fi
grep -Fq 'unchecked: curl;' "$test_root/package-drift.log"
printf 'PASS: the Parrot verifier checks exactly the registry package rows\n'
grep -Fq 'python3 remains Parrot/APT-owned' <<<"$verification_output"
grep -Fq 'Neovim 0.12.5 satisfies the >= 0.12 baseline' <<<"$verification_output"
grep -Fq 'Mason inventory exactly matches the reduced Parrot profile' <<<"$verification_output"
grep -Fq 'Reduced LazyVim plugins match the Parrot lockfile' <<<"$verification_output"
grep -Fq 'VERIFIED: default route/interface observed' <<<"$verification_output"
grep -Fq 'NOT OBSERVED: mounted 9p or virtiofs host filesystem' <<<"$verification_output"
grep -Fq 'MANUAL ASSURANCE REQUIRED:' <<<"$verification_output"

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
printf 'PASS: an unlisted Mason package is a failure, not a warning, on this profile\n'

# The reduced profile is a set *and* a claim that each member is installed.
# Comparing directory names alone let an empty or interrupted package satisfy
# it (#366), which is the same defect #346 fixed in the shared verifier. Each
# case damages one package; the five beside it must keep passing, so a check
# that had started failing everything would be caught here too.
mason_damaged_package="ruff"
mason_healthy_package="stylua"
mason_inventory_text="$(printf '%s\n' "${parrot_mason_packages[@]}")"
for mason_package in "$mason_damaged_package" "$mason_healthy_package"; do
  grep -Fxq "$mason_package" <<<"$mason_inventory_text" || {
    printf 'The reduced profile no longer lists %s, so these cases prove nothing\n' \
      "$mason_package" >&2
    exit 1
  }
done

mason_damage_case() {
  local case_name="$1"
  local expected="$2"
  local log="$test_root/mason-$case_name.log"

  if "${verify_environment[@]}" \
    "$repo_root/platforms/parrot-ctf/scripts/verify.sh" >"$log" 2>&1; then
    printf 'Parrot verification accepted a Mason package left %s.\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$log" || {
    printf 'The "left %s" case was not reported clearly:\n' "$case_name" >&2
    cat "$log" >&2
    exit 1
  }
  # The set is still exactly right, so this is the identity check speaking and
  # not the name comparison finding a package gone.
  if grep -Fq 'Mason inventory mismatch' "$log"; then
    printf 'The "left %s" case changed the package set; it must not.\n' "$case_name" >&2
    exit 1
  fi
  grep -Fq "Mason: $mason_healthy_package" "$log" || {
    printf 'The undamaged package stopped passing in the "left %s" case.\n' "$case_name" >&2
    exit 1
  }
  printf 'PASS: Parrot verification rejects a Mason package left %s\n' "$case_name"
}

mason_restore_damaged() {
  rm -rf -- "$parrot_mason_root/packages/$mason_damaged_package"
  "$mason_mock_install" --pins "$repo_root/common/mason-package-versions.txt" \
    "$parrot_mason_root" "$mason_damaged_package"
}

# The reproduction: a directory and nothing in it.
rm -rf -- "$parrot_mason_root/packages/$mason_damaged_package"
mkdir -p "$parrot_mason_root/packages/$mason_damaged_package"
mason_damage_case empty \
  "Mason package $mason_damaged_package is not completely installed"
mason_restore_damaged

# An install interrupted after its files were promoted and linked, before the
# receipt was written.
rm -f -- "$parrot_mason_root/packages/$mason_damaged_package/mason-receipt.json"
mason_damage_case interrupted \
  "Mason package $mason_damaged_package is not completely installed"
mason_restore_damaged

# The executable the receipt claims, gone from Mason's bin directory.
rm -f -- "$parrot_mason_root/bin/$mason_damaged_package"
mason_damage_case unlinked \
  "$parrot_mason_root/bin/$mason_damaged_package, which is missing or not executable"
mason_restore_damaged

# ...and the repaired profile passes again, unchanged by being verified.
mason_tree_before="$(find "$parrot_mason_root" -type f -exec sha256sum {} + | sort)"
[[ -n "$mason_tree_before" ]] || {
  printf 'The Mason fixture wrote no files, so the untouched check proves nothing\n' >&2
  exit 1
}
if ! "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/mason-healthy.log" 2>&1; then
  printf 'Parrot verification failed a complete reduced Mason profile:\n' >&2
  cat "$test_root/mason-healthy.log" >&2
  exit 1
fi
for mason_package in "${parrot_mason_packages[@]}"; do
  grep -Fq "Mason: $mason_package" "$test_root/mason-healthy.log" || {
    printf 'A complete Mason package was not reported as installed: %s\n' \
      "$mason_package" >&2
    exit 1
  }
done
[[ "$mason_tree_before" == \
  "$(find "$parrot_mason_root" -type f -exec sha256sum {} + | sort)" ]] || {
  printf 'Verifying a complete Mason installation changed it\n' >&2
  exit 1
}
printf 'PASS: a complete reduced Mason profile passes and is left untouched\n'

ln -s /usr/bin/true "$local_bin/nmap"
if "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/shadowed-tool.log" 2>&1; then
  printf 'Parrot verification accepted a user security-tool shim.\n' >&2
  exit 1
fi
grep -Fq 'Protected security-tool shim present: nmap' "$test_root/shadowed-tool.log"
grep -Fq 'command -v:' "$test_root/shadowed-tool.log"

unlink "$local_bin/nmap"
unlink "$mock_bin/john"
if "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/missing-tool.log" 2>&1; then
  printf 'Parrot verification accepted an installed but unresolvable john executable.\n' >&2
  exit 1
fi
grep -Fq 'john is installed by Parrot but is not resolvable' "$test_root/missing-tool.log"

# The Parrot verifier reaches mise too, and is read-only about the context it
# resolves from (issue #345).
printf '[tools]\nstray = "1"\n' >"$parrot_mise_context/.mise.toml"
stray_digest="$(sha256sum <"$parrot_mise_context/.mise.toml" | cut -d ' ' -f 1)"
if "${verify_environment[@]}" \
  "$repo_root/platforms/parrot-ctf/scripts/verify.sh" \
  >"$test_root/stray-context.log" 2>&1; then
  printf 'Parrot verification accepted a contaminated mise context.\n' >&2
  exit 1
fi
grep -Fq 'mise resolution is not deterministic' "$test_root/stray-context.log"
grep -Fq '.mise.toml' "$test_root/stray-context.log"
if [[ ! -f "$parrot_mise_context/.mise.toml" ]]; then
  printf 'Parrot verification deleted the stray declaration it was meant to report.\n' >&2
  exit 1
fi
if [[ "$stray_digest" != "$(sha256sum <"$parrot_mise_context/.mise.toml" | cut -d ' ' -f 1)" ]]; then
  printf 'Parrot verification rewrote the stray declaration in the mise context.\n' >&2
  exit 1
fi
rm -f "$parrot_mise_context/.mise.toml"
printf 'PASS: the Parrot verifier reports a contaminated mise context and leaves it in place\n'

printf 'Parrot clean-install and PATH ownership verification tests passed.\n'