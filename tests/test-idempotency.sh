#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

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
    "$repo_root/scripts/setup-local.sh" "$flavour" >/dev/null
}

run_stow() {
  local home="$1"

  HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    "$repo_root/scripts/stow.sh" >/dev/null
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
for command in bash cat chmod dirname mkdir mktemp mv readlink; do
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

for identity in local drdk; do
  identity_path="$legacy_home/.config/git/$identity"
  [[ -f "$identity_path" && ! -L "$identity_path" ]]
  [[ -s "$identity_path" ]]
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
mock_bin="$test_root/mock-bin"
mkdir -p \
  "$bootstrap_config/git" \
  "$bootstrap_data/tmux/plugins" \
  "$bootstrap_cache" \
  "$mock_bin"

cat >"$mock_bin/mock-command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -q && "$2" == terra-release ]]
EOF

cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$mock_bin/mock-command" "$mock_bin/rpm" "$mock_bin/sudo"

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
  mise
  neovim-node-host
  node
  nvim
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
  "PATH=$mock_bin:$PATH"
)

run_bootstrap() {
  local output="$test_root/bootstrap.log"

  if ! "${bootstrap_environment[@]}" \
    "$repo_root/install.sh" \
    --theme macchiato --no-kde --no-latex --non-interactive \
    >"$output" 2>&1; then
    printf 'Complete mocked bootstrap failed:\n' >&2
    sed -n '1,240p' "$output" >&2
    exit 1
  fi
}

run_bootstrap

bootstrap_identity="$(sha256sum "$bootstrap_config/git/local")"
bootstrap_notes="$(sha256sum "$bootstrap_home/notes")"

run_bootstrap

[[ "$(sha256sum "$bootstrap_config/git/local")" == "$bootstrap_identity" ]]
[[ "$(sha256sum "$bootstrap_home/notes")" == "$bootstrap_notes" ]]
[[ -L "$bootstrap_config/git/config" ]]
[[ -L "$bootstrap_home/.local/bin/theme" ]]
printf 'PASS: a complete mocked bootstrap succeeds twice without side effects\n'

printf 'Bootstrap idempotency and upgrade tests passed.\n'
