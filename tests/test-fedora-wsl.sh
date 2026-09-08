#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || {
    printf 'Expected output to contain %q:\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --ocaml)"
assert_contains "$dry_run" 'Fedora WSL installation plan'
assert_contains "$dry_run" 'common/install-mise.sh'
assert_contains "$dry_run" 'common/install-neovim-tools.sh'
assert_contains "$dry_run" 'common/install-ocaml.sh'
assert_contains "$dry_run" "Set Zsh as the user's default login shell."
assert_contains "$dry_run" 'Excluded: KDE, Sway, Ghostty, ASUS/ROG, NVIDIA, VM host/guest, desktop,'
assert_contains "$dry_run" 'platforms/fedora-wsl/scripts/configure-interop.sh'
assert_contains "$dry_run" 'enabled=true'
assert_contains "$dry_run" 'appendWindowsPath=false'

latex_off_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run)"
assert_contains "$latex_off_dry_run" 'LaTeX toolchain:    false'

latex_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --latex)"
assert_contains "$latex_dry_run" 'LaTeX toolchain:    true'
assert_contains "$latex_dry_run" 'platforms/fedora/scripts/install-latex.sh'
assert_contains "$latex_dry_run" 'latexmk, latexindent, Biber'
assert_contains "$latex_dry_run" 'platforms/fedora-wsl/scripts/verify.sh --latex'

containers_off_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run)"
assert_contains "$containers_off_dry_run" 'Containers profile: false'

containers_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --containers)"
assert_contains "$containers_dry_run" 'Containers profile: true'
assert_contains "$containers_dry_run" \
  'platforms/fedora-wsl/scripts/install-containers.sh'

containers_socket_dry_run="$("$repo_root/install.sh" --platform fedora-wsl \
  --dry-run --containers --containers-api-socket)"
assert_contains "$containers_socket_dry_run" 'Containers API socket: true'
assert_contains "$containers_socket_dry_run" 'install-containers.sh --api-socket'

if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --containers-api-socket >"$test_root/api-socket-without-containers.log" 2>&1; then
  printf 'fedora-wsl accepted --containers-api-socket without --containers.\n' >&2
  exit 1
fi
grep -Fq -- '--containers-api-socket requires --containers' \
  "$test_root/api-socket-without-containers.log"

if "$repo_root/install.sh" --platform unknown --dry-run \
  >"$test_root/invalid.log" 2>&1; then
  printf 'Unknown root platform unexpectedly succeeded.\n' >&2
  exit 1
fi
grep -Fq 'Unsupported platform: unknown' "$test_root/invalid.log"

if WSL_DISTRO_NAME='' KERNEL_RELEASE_FILE="$test_root/not-wsl" \
  "$repo_root/platforms/fedora-wsl/scripts/install-system.sh" \
  >"$test_root/not-wsl.log" 2>&1; then
  printf 'Fedora WSL package installer accepted a non-WSL host.\n' >&2
  exit 1
fi
grep -Fq 'must run inside Windows Subsystem for Linux' "$test_root/not-wsl.log"

mock_bin="$test_root/bin"
home="$test_root/home"
config="$home/.config"
stow_log="$test_root/stow.log"
command_log="$test_root/commands.log"
shell_state="$test_root/login-shell"
mkdir -p "$mock_bin" "$config"
printf 'ID=fedora\n' >"$test_root/os-release"
printf '/bin/bash\n' >"$shell_state"

cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
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
cat >"$mock_bin/zsh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
url=""
while (($#)); do
  if [[ "$1" == --output ]]; then
    output="$2"
    shift 2
  elif [[ "$1" == http* ]]; then
    url="$1"
    shift
  else
    shift
  fi
done
if [[ "$url" == *starship.rs* ]]; then
  printf '%s\n' '#!/usr/bin/env sh' \
    'while [ "$#" -gt 0 ]; do' \
    '  if [ "$1" = "--bin-dir" ]; then bin_dir="$2"; shift 2; else shift; fi' \
    'done' \
    '[ -d "$bin_dir" ] || exit 1' \
    'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$bin_dir/starship"' \
    'chmod +x "$bin_dir/starship"' >"$output"
else
  printf '%s\n' '#!/usr/bin/env sh' \
    'mkdir -p "$(dirname "$MISE_INSTALL_PATH")"' \
    'printf "#!/usr/bin/env sh\\nexit 0\\n" >"$MISE_INSTALL_PATH"' \
    'chmod +x "$MISE_INSTALL_PATH"' >"$output"
fi
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
  "WSL_DISTRO_NAME=FedoraLinux"
  "OS_RELEASE_FILE=$test_root/os-release"
  "COMMAND_LOG=$command_log"
  "SHELL_STATE=$shell_state"
)

"${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-system.sh" >/dev/null
[[ -x "$home/.local/bin/mise" ]]
[[ -x "$home/.local/bin/starship" ]]
expected_zsh_path="$(PATH="$mock_bin:/usr/bin:/bin" command -v zsh)"
grep -Fq 'sudo dnf install -y bat bzip2 curl eza fd-find fzf gawk' "$command_log"
grep -Fq "sudo usermod --shell $expected_zsh_path fedora-test" "$command_log"
grep -Fqx "$expected_zsh_path" "$shell_state"
if grep -Fq ' starship' "$command_log"; then
  printf 'Fedora WSL must not request unavailable Starship from DNF.\n' >&2
  exit 1
fi

if grep -Fq 'awk ' "$repo_root/platforms/fedora-wsl/lib/wsl.sh"; then
  printf 'Fedora WSL preflight must not require awk before prerequisites are installed.\n' >&2
  exit 1
fi

first_mise="$(sha256sum "$home/.local/bin/mise")"
"${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-system.sh" >/dev/null
[[ "$(sha256sum "$home/.local/bin/mise")" == "$first_mise" ]]
[[ "$(grep -Fc "sudo usermod --shell $expected_zsh_path fedora-test" "$command_log")" == 1 ]]

STOW_LOG="$stow_log" HOME="$home" XDG_CONFIG_HOME="$config" \
  PATH="$mock_bin:/usr/bin:/bin" \
  "$repo_root/platforms/fedora-wsl/scripts/stow.sh" >/dev/null

for package in bat bin fzf git lazygit mise nvim-lazyvim starship tmux zsh \
  interop nvim-wsl theme-hooks zsh-platform; do
  grep -Fqx "$package" "$stow_log"
done

for rejected in ghostty sway waybar; do
  if grep -Fqx "$rejected" "$stow_log"; then
    printf 'Fedora WSL Stow deployed rejected package: %s\n' "$rejected" >&2
    exit 1
  fi
done

real_home="$test_root/real-home"
mkdir -p "$real_home"
HOME="$real_home" XDG_CONFIG_HOME="$real_home/.config" \
  "$repo_root/platforms/fedora-wsl/scripts/stow.sh" >/dev/null
HOME="$real_home" XDG_CONFIG_HOME="$real_home/.config" \
  "$repo_root/platforms/fedora-wsl/scripts/stow.sh" >/dev/null

[[ -L "$real_home/.zshenv" ]]
[[ -L "$real_home/.config/nvim/init.lua" ]]
[[ -L "$real_home/.config/nvim/lua/plugins/wsl.lua" ]]
[[ -L "$real_home/.local/bin/wsl-copy" ]]
[[ -L "$real_home/.config/dotfiles/theme-hooks.d/fedora-wsl.sh" ]]
[[ ! -e "$real_home/.config/ghostty/config" ]]

platform_env="$repo_root/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform-env.zsh"
platform_zsh="$repo_root/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform.zsh"
grep -Fq '/mnt/[a-zA-Z]/*)' "$platform_env"
grep -Fq 'export BROWSER=wsl-open' "$platform_env"
grep -Fq 'vim.g.vimtex_view_general_viewer = "wsl-open"' \
  "$repo_root/platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua"
grep -Fq 'platform-env.zsh' "$repo_root/zsh/.zshenv"
grep -Fq '/usr/share/zsh-autosuggestions' "$platform_zsh"

nvim_wsl="$repo_root/platforms/fedora-wsl/stow/nvim-wsl/.config/nvim/lua/plugins/wsl.lua"
grep -Fq 'vim.fn.has("wsl")' "$nvim_wsl"
grep -Fq '"wsl-copy"' "$nvim_wsl"
grep -Fq '"wsl-paste"' "$nvim_wsl"

windows_root="$test_root/windows"
mkdir -p "$windows_root/System32/WindowsPowerShell/v1.0"

cat >"$windows_root/System32/clip.exe" <<'EOF'
#!/usr/bin/env bash
cat >"$CLIPBOARD_LOG"
EOF
cat >"$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'Get-Clipboard'* ]]; then
  printf 'first\r\nsecond\r\n'
else
  printf '%s\n' "$*" >"$POWERSHELL_LOG"
fi
EOF
cat >"$windows_root/explorer.exe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$OPEN_LOG"
EOF
cat >"$windows_root/System32/cmd.exe" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == /c && "$2" == echo && "$3" == interop-ok ]]; then
  printf 'interop-ok\r\n'
  exit 0
fi
exit 1
EOF
chmod +x \
  "$windows_root/System32/clip.exe" \
  "$windows_root/System32/WindowsPowerShell/v1.0/powershell.exe" \
  "$windows_root/explorer.exe" \
  "$windows_root/System32/cmd.exe"

printf 'clipboard text' |
  WINDOWS_SYSTEM_ROOT="$windows_root" CLIPBOARD_LOG="$test_root/clipboard.log" \
  "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-copy"
grep -Fqx 'clipboard text' "$test_root/clipboard.log"

paste_output="$(WINDOWS_SYSTEM_ROOT="$windows_root" \
  "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-paste")"
[[ "$paste_output" == $'first\nsecond' ]]

WINDOWS_SYSTEM_ROOT="$windows_root" OPEN_LOG="$test_root/open.log" \
  "$repo_root/platforms/fedora-wsl/stow/interop/.local/bin/wsl-open" \
  'https://example.invalid/path?q=one two'
grep -Fqx 'https://example.invalid/path?q=one two' "$test_root/open.log"

HOME="$real_home" XDG_CONFIG_HOME="$real_home/.config" \
  WINDOWS_SYSTEM_ROOT="$windows_root" POWERSHELL_LOG="$test_root/powershell.log" \
  "$repo_root/bin/.local/bin/theme" mocha >/dev/null
grep -Fq 'noctty\dotfiles\set-theme.ps1' "$test_root/powershell.log"
grep -Fq -- '-Flavor "mocha"' "$test_root/powershell.log"

bootstrap_home="$test_root/bootstrap-home"
bootstrap_config="$bootstrap_home/.config"
bootstrap_data="$bootstrap_home/.local/share"
bootstrap_bin="$test_root/bootstrap-bin"
bootstrap_shell_state="$test_root/bootstrap-login-shell"
bootstrap_command_log="$test_root/bootstrap-commands.log"
mkdir -p \
  "$bootstrap_config/git" \
  "$bootstrap_data/tmux/plugins" \
  "$bootstrap_bin"
printf '/bin/bash\n' >"$bootstrap_shell_state"

cat >"$bootstrap_bin/mock-command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$bootstrap_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
if [[ "$1" == usermod && "$2" == --shell ]]; then
  printf '%s\n' "$3" >"$SHELL_STATE"
fi
exit 0
EOF
cat >"$bootstrap_bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '1000\n' ;;
  -un) printf 'fedora-test\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF
cat >"$bootstrap_bin/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == passwd && "${2:-}" == fedora-test ]]; then
  printf 'fedora-test:x:1000:1000:Fedora Test:/home/fedora-test:%s\n' \
    "$(<"$SHELL_STATE")"
else
  /usr/bin/getent "$@"
fi
EOF
chmod +x "$bootstrap_bin/mock-command" "$bootstrap_bin/sudo" \
  "$bootstrap_bin/id" "$bootstrap_bin/getent"

bootstrap_commands=(
  ast-grep bat biber curl delta dnf dotnet dotnet-easydotnet eza fd fzf gh
  latex latexindent latexmk lazygit lualatex neovim-node-host node npm npx
  pdflatex python rg rpm shellcheck sqlite3 starship tmux tree-sitter uv
  xelatex zoxide zsh
)
for command_name in "${bootstrap_commands[@]}"; do
  ln -s mock-command "$bootstrap_bin/$command_name"
done

cat >"$bootstrap_bin/mise" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == exec && "${2:-}" == -- ]]; then
  shift 2
  exec "$@"
fi
exit 0
EOF
cat >"$bootstrap_bin/nvim" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == */common/bootstrap-mason.lua ]]; then
    for package in $DOTFILES_MASON_PACKAGES; do
      mkdir -p "$XDG_DATA_HOME/nvim/mason/packages/$package"
    done
  fi
done
EOF
chmod +x "$bootstrap_bin/mise" "$bootstrap_bin/nvim"

rm -- "$bootstrap_bin/zsh"
cat >"$bootstrap_bin/zsh" <<'EOF'
#!/usr/bin/env bash
printf '\033[H\033[2J\033[3J'
if [[ "$*" == *'__DOTFILES_VERIFY_PATH__'* ]]; then
  printf '\n__DOTFILES_VERIFY_PATH__%s\n' "$PATH"
elif [[ "$*" == *'__DOTFILES_VERIFY_STARSHIP__'* ]]; then
  printf '\n__DOTFILES_VERIFY_STARSHIP__%s\n' \
    "$XDG_CONFIG_HOME/starship/catppuccin-macchiato.toml"
fi
printf '\033[H\033[2J\033[3J\n'
EOF
chmod +x "$bootstrap_bin/zsh"

theme_origin="$test_root/tmux-theme-origin"
mkdir -p "$theme_origin"
git -C "$theme_origin" init -q
git -C "$theme_origin" config user.name WSL-Test
git -C "$theme_origin" config user.email wsl@example.invalid
printf '# test theme\n' >"$theme_origin/catppuccin.tmux"
git -C "$theme_origin" add catppuccin.tmux
git -C "$theme_origin" commit -qm 'Add test theme'
git -C "$theme_origin" tag v2.3.0
git clone -q "$theme_origin" "$bootstrap_data/tmux/plugins/catppuccin"

printf '[user]\n    name = Private WSL User\n' >"$bootstrap_config/git/local"
printf 'unrelated state\n' >"$bootstrap_home/notes"

bootstrap_environment=(
  env
  "HOME=$bootstrap_home"
  "XDG_CONFIG_HOME=$bootstrap_config"
  "XDG_DATA_HOME=$bootstrap_data"
  "PATH=$bootstrap_home/.local/bin:$bootstrap_bin:$PATH"
  "WSL_DISTRO_NAME=FedoraLinux"
  "OS_RELEASE_FILE=$test_root/os-release"
  "SHELL_STATE=$bootstrap_shell_state"
  "BOOTSTRAP_COMMAND_LOG=$bootstrap_command_log"
  "WINDOWS_SYSTEM_ROOT=$windows_root"
  "WSL_CONF_FILE=$test_root/bootstrap-wsl.conf"
)

run_bootstrap() {
  if ! "${bootstrap_environment[@]}" \
    "$repo_root/install.sh" --platform fedora-wsl --non-interactive "$@" \
    >"$test_root/bootstrap.log" 2>&1; then
    printf 'Complete mocked Fedora WSL bootstrap failed:\n' >&2
    sed -n '1,240p' "$test_root/bootstrap.log" >&2
    exit 1
  fi
}

run_bootstrap
grep -Fq 'Ensuring explicit Windows executable interop stays available' \
  "$test_root/bootstrap.log"
grep -Fq 'explicit Windows executable interop works' "$test_root/bootstrap.log"
grep -Fq 'sudo install -m 0644' "$bootstrap_command_log"

bootstrap_identity="$(sha256sum "$bootstrap_config/git/local")"
bootstrap_notes="$(sha256sum "$bootstrap_home/notes")"
run_bootstrap

if grep -Fq 'texlive-scheme-medium' "$bootstrap_command_log"; then
  printf 'Default Fedora WSL bootstrap unexpectedly installed LaTeX.\n' >&2
  exit 1
fi

run_bootstrap --latex
grep -Fq \
  'sudo dnf install -y texlive-scheme-medium latexmk biber texlive-biblatex texlive-latexindent' \
  "$bootstrap_command_log"
grep -Fq 'LaTeX toolchain' "$test_root/bootstrap.log"

[[ "$(sha256sum "$bootstrap_config/git/local")" == "$bootstrap_identity" ]]
[[ "$(sha256sum "$bootstrap_home/notes")" == "$bootstrap_notes" ]]
[[ -L "$bootstrap_home/.zshenv" ]]
[[ -L "$bootstrap_config/zsh/platform-env.zsh" ]]
[[ ! -e "$bootstrap_config/ghostty/config" ]]
grep -Fqx "$bootstrap_bin/zsh" "$bootstrap_shell_state"

printf 'Fedora WSL platform composition, safety and idempotency tests passed.\n'
