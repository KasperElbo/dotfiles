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
test_isolate_path git jq sha256sum stow timeout
test_new_root
test_root="$TEST_ROOT"

dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --ocaml)"
assert_contains "$dry_run" 'Fedora WSL installation plan'
assert_contains "$dry_run" 'common/install-mise.sh'
assert_contains "$dry_run" 'common/install-neovim-tools.sh'
assert_contains "$dry_run" 'common/install-ocaml.sh'
assert_contains "$dry_run" "Set Zsh as the user's default login shell."
assert_contains "$dry_run" \
  'Excluded: KDE, Sway, Ghostty, ASUS/ROG, NVIDIA, VM host/guest, and desktop.'
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

# Tailscale is intentionally unsupported on Fedora WSL (host-only Tailscale
# on Windows is the recommended architecture); the flag must be explicitly
# rejected with a clear pointer, not silently ignored or accepted.
if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --tailscale >"$test_root/tailscale-rejected.log" 2>&1; then
  printf 'fedora-wsl unexpectedly accepted --tailscale.\n' >&2
  exit 1
fi
grep -Fq -- '--tailscale is not supported on Fedora WSL' \
  "$test_root/tailscale-rejected.log"
grep -Fq 'install Tailscale on the Windows host instead' \
  "$test_root/tailscale-rejected.log"

ai_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --ai)"
assert_contains "$ai_dry_run" 'AI profile:         true'
assert_contains "$ai_dry_run" 'common/install-ai.sh'

ai_off_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run)"
assert_contains "$ai_off_dry_run" 'AI profile:         false'

ai_full_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --ai --codex --firstmate --gnhf --backpass)"
assert_contains "$ai_full_dry_run" 'AI Codex subcomponent:     true'
assert_contains "$ai_full_dry_run" 'AI FirstMate subcomponent: true'
assert_contains "$ai_full_dry_run" 'AI GNHF subcomponent:      true'
assert_contains "$ai_full_dry_run" 'AI backpass subcomponent:  true'
assert_contains "$ai_full_dry_run" 'common/install-ai.sh --codex --firstmate --gnhf --backpass'

ai_backpass_only_dry_run="$("$repo_root/install.sh" --platform fedora-wsl \
  --dry-run --ai --backpass)"
# Additive semantics: an omitted --firstmate is "leave it alone", not "remove".
assert_contains "$ai_backpass_only_dry_run" 'AI FirstMate subcomponent: inherit'
assert_contains "$ai_backpass_only_dry_run" 'AI backpass subcomponent:  true'

# All four sub-flags say "inherit" when omitted (#225, DOC-040): GNHF and
# backpass used to print an empty value while the recorded selection one line
# below said inherit.
ai_inherit_dry_run="$("$repo_root/install.sh" --platform fedora-wsl --dry-run --ai)"
assert_contains "$ai_inherit_dry_run" 'AI Codex subcomponent:     inherit'
assert_contains "$ai_inherit_dry_run" 'AI FirstMate subcomponent: inherit'
assert_contains "$ai_inherit_dry_run" 'AI GNHF subcomponent:      inherit'
assert_contains "$ai_inherit_dry_run" 'AI backpass subcomponent:  inherit'
assert_contains "$ai_inherit_dry_run" \
  'codex:inherit,firstmate:inherit,gnhf:inherit,backpass:inherit'
assert_contains "$ai_backpass_only_dry_run" 'common/install-ai.sh --backpass'

if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --codex >"$test_root/codex-without-ai.log" 2>&1; then
  printf 'fedora-wsl accepted --codex without --ai.\n' >&2
  exit 1
fi
grep -Fq -- '--codex/--no-codex requires --ai' "$test_root/codex-without-ai.log"

if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --firstmate >"$test_root/firstmate-without-ai.log" 2>&1; then
  printf 'fedora-wsl accepted --firstmate without --ai.\n' >&2
  exit 1
fi
grep -Fq -- '--firstmate/--no-firstmate requires --ai' "$test_root/firstmate-without-ai.log"

if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --gnhf >"$test_root/gnhf-without-ai.log" 2>&1; then
  printf 'fedora-wsl accepted --gnhf without --ai.\n' >&2
  exit 1
fi
grep -Fq -- '--gnhf/--no-gnhf requires --ai' "$test_root/gnhf-without-ai.log"

if "$repo_root/install.sh" --platform fedora-wsl --dry-run \
  --backpass >"$test_root/backpass-without-ai.log" 2>&1; then
  printf 'fedora-wsl accepted --backpass without --ai.\n' >&2
  exit 1
fi
grep -Fq -- '--backpass/--no-backpass requires --ai' "$test_root/backpass-without-ai.log"

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

test_stub_init "$test_root"
test_stub_install "$test_root" dnf
test_stub_install "$test_root" sudo
fedora_wsl_packages=(
  bat bzip2 curl eza fd-find fzf gawk gcc gcc-c++ gh git git-delta jq libicu
  make neovim openssh-clients procps-ng ripgrep ShellCheck shadow-utils sqlite
  sqlite-devel stow tmux unzip zoxide zsh zsh-autosuggestions
  zsh-syntax-highlighting
)
test_stub_allow "$test_root" dnf install -y "${fedora_wsl_packages[@]}"
test_stub_allow "$test_root" sudo dnf install -y "${fedora_wsl_packages[@]}"
test_stub_allow "$test_root" sudo usermod --shell "$mock_bin/zsh" fedora-test

cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$test_root/handlers/sudo" <<'EOF'
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
cat >"$mock_bin/wslpath" <<'EOF'
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
chmod +x "$mock_bin"/* "$test_root/handlers/sudo"

test_environment=(
  env
  "HOME=$home"
  "XDG_CONFIG_HOME=$config"
  "PATH=$mock_bin:$PATH"
  "WSL_DISTRO_NAME=FedoraLinux"
  "OS_RELEASE_FILE=$test_root/os-release"
  "COMMAND_LOG=$command_log"
  "SHELL_STATE=$shell_state"
)

install_system_output="$("${test_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/install-system.sh")"
assert_contains "$install_system_output" 'Zsh is now configured as your login shell.'
assert_contains "$install_system_output" \
  'This Noctty session was started before that change; open a new Noctty/WSL'
[[ -x "$home/.local/bin/mise" ]]
[[ -x "$home/.local/bin/starship" ]]
expected_zsh_path="$(PATH="$mock_bin:$PATH" command -v zsh)"
grep -Fq 'sudo dnf install -y bat bzip2 curl eza fd-find fzf gawk' "$command_log"
grep -Fq 'gh git git-delta jq libicu' "$command_log"
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
  PATH="$mock_bin:$PATH" \
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
# The sanitizer's own behaviour is not checked here. This suite replaces zsh
# with a Bash stub that computes PATH itself, so a grep for the case-arm text
# would match the source of a file no test ever interprets -- and did, while an
# inverted sanitizer that kept every Windows path passed the whole gate stack.
# tests/test-wsl-path-sanitizer.sh runs the tracked file under real Zsh instead.
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
bootstrap_stub_root="$test_root/bootstrap-stubs"
bootstrap_bin="$bootstrap_stub_root/bin"
# The verifier expects the bundled debugger for the host's own architecture.
case "$(uname -m)" in aarch64 | arm64) debugger_rid=linux-arm64 ;; *) debugger_rid=linux-x64 ;; esac
debugger_path="$test_root/easydotnet/tools/netcoredbg/$debugger_rid/netcoredbg"
bootstrap_shell_state="$test_root/bootstrap-login-shell"
bootstrap_command_log="$test_root/bootstrap-commands.log"
mkdir -p \
  "$bootstrap_config/git" \
  "$bootstrap_data/tmux/plugins" \
  "$bootstrap_bin" \
  "$(dirname "$debugger_path")"
printf '/bin/bash\n' >"$bootstrap_shell_state"
touch "$debugger_path"
chmod +x "$debugger_path"

test_stub_init "$bootstrap_stub_root"
test_stub_install "$bootstrap_stub_root" dnf
test_stub_install "$bootstrap_stub_root" sudo
test_stub_allow "$bootstrap_stub_root" dnf install -y \
  "${fedora_wsl_packages[@]}"
test_stub_allow "$bootstrap_stub_root" dnf install -y \
  texlive-scheme-medium latexmk biber texlive-biblatex texlive-latexindent
test_stub_allow "$bootstrap_stub_root" sudo -n -v
test_stub_allow "$bootstrap_stub_root" sudo dnf install -y \
  "${fedora_wsl_packages[@]}"
test_stub_allow "$bootstrap_stub_root" sudo dnf install -y \
  texlive-scheme-medium latexmk biber texlive-biblatex texlive-latexindent
test_stub_allow "$bootstrap_stub_root" sudo usermod --shell \
  "$bootstrap_bin/zsh" fedora-test

cat >"$bootstrap_bin/mock-command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$bootstrap_stub_root/handlers/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$BOOTSTRAP_COMMAND_LOG"
if [[ "$1" == usermod && "$2" == --shell ]]; then
  printf '%s\n' "$3" >"$SHELL_STATE"
  exit 0
fi
case "$1" in
dnf | install) exec "$@" ;;
*) exit 0 ;;
esac
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
cat >"$bootstrap_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
path="$(/usr/bin/mktemp "$@")" || exit
if (($# == 0)); then
  printf 'install -m 0644 %q %q\n' "$path" "$WSL_CONF_FILE" \
    >>"$TEST_STUB_ROOT/contracts/sudo.allow"
fi
printf '%s\n' "$path"
EOF
chmod +x "$bootstrap_bin/mock-command" \
  "$bootstrap_bin/id" "$bootstrap_bin/getent"
chmod +x "$bootstrap_stub_root/handlers/sudo" "$bootstrap_bin/mktemp"

# The disk preflight must decide on a known figure, never on the free space of
# the machine running the tests.
test_stub_roomy_df "$bootstrap_bin"

bootstrap_commands=(
  bat biber curl delta eza fd fzf gh latex latexindent latexmk lualatex
  pdflatex rg rpm shellcheck sqlite3 starship tmux wslpath xelatex zoxide zsh
)
for command_name in "${bootstrap_commands[@]}"; do
  ln -s mock-command "$bootstrap_bin/$command_name"
done

# The runtimes mise owns are installed the way mise installs them: under its
# installs directory, reached through its shims, and reported by `mise which`.
# The verifier proves that ownership, so a plain PATH stub would not pass it.
bootstrap_mise_tools=(
  ast-grep dotnet dotnet-easydotnet lazygit neovim-node-host node npm npx
  python tree-sitter uv
)
mkdir -p "$bootstrap_data/mise/shims"
for command_name in "${bootstrap_mise_tools[@]}"; do
  install_bin="$bootstrap_data/mise/installs/$command_name/latest/bin/$command_name"
  mkdir -p "$(dirname "$install_bin")"
  cp "$bootstrap_bin/mock-command" "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" \
    >"$bootstrap_data/mise/shims/$command_name"
  chmod +x "$install_bin" "$bootstrap_data/mise/shims/$command_name"
done

cat >"$bootstrap_data/mise/installs/dotnet-easydotnet/latest/bin/dotnet-easydotnet" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == healthcheck ]]; then
  platform="$(basename "$(dirname "$MOCK_EASY_DOTNET_DEBUGGER")")"
  printf '[{"type":"ok","name":"debugger.engine","value":"netcoredbg"},{"type":"ok","name":"debugger.source","value":"bundled"},{"type":"ok","name":"debugger.platform","value":"%s"},{"type":"ok","name":"debugger.path","value":"%s"},{"type":"ok","name":"debugger.version","value":"NET Core debugger test version"}]\n' \
    "$platform" "$MOCK_EASY_DOTNET_DEBUGGER"
fi
EOF

cat >"$bootstrap_bin/mise" <<'EOF'
#!/usr/bin/env bash
# Every call this fixture does not implement is refused. It used to fall off
# the end of the chain below into a bare `exit 0`, so a mise call added to the
# installer returned success and no output, and the suite went on green: the
# fixture answered for a command it had never been taught. A refusal is how a
# new call announces that this stub has to decide what it means.
reject() {
  printf 'strict mise fixture rejected unsupported argv:' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 96
}

make_ai_tool() {
  name="$1"
  install_bin="$XDG_DATA_HOME/mise/installs/$name/latest/bin/$name"
  shim="$XDG_DATA_HOME/mise/shims/$name"
  mkdir -p "$(dirname "$install_bin")" "$(dirname "$shim")"
  if [[ "$name" == claude ]]; then
    printf '#!/usr/bin/env bash\nprintf "1.0.0 (Claude Code)\\n"\n' >"$install_bin"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$install_bin"
  fi
  chmod +x "$install_bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$install_bin" >"$shim"
  chmod +x "$shim"
}

if [[ "${1:-}" == --version && $# -eq 1 ]]; then
  printf '2025.1.0 linux-x64 (fixture)\n'
  exit 0
elif [[ "${1:-}" == --yes && "${2:-}" == install ]]; then
  conf="$XDG_CONFIG_HOME/mise/conf.d/ai.toml"
  [[ -f "$conf" ]] && make_ai_tool claude
  [[ -f "$conf" ]] && make_ai_tool herdr
  exit 0
elif [[ "${1:-}" == ls && "${3:-}" == --json ]]; then
  # The resolved-version lookup, answered from what this stub installed.
  name="${2#npm:}"
  name="${name##*/}"
  [[ "$name" != claude-code ]] || name=claude
  if [[ -x "$XDG_DATA_HOME/mise/shims/$name" ]]; then
    printf '[{"version":"1.2.3","requested_version":"latest",'
    printf '"install_path":"%s/mise/installs/%s/latest",' "$XDG_DATA_HOME" "$name"
    printf '"installed":true,"active":true}]\n'
  else
    printf '[]\n'
  fi
  exit 0
elif [[ "${1:-}" == which && $# -eq 2 ]]; then
  candidate="$XDG_DATA_HOME/mise/installs/${2}/latest/bin/${2}"
  [[ -x "$candidate" ]] || exit 1
  printf '%s\n' "$candidate"
  exit 0
elif [[ "${1:-}" == exec && "${2:-}" == -- && $# -ge 3 ]]; then
  shift 2
  PATH="$XDG_DATA_HOME/mise/shims:$PATH"
  exec "$@"
fi
reject "$@"
EOF
cat >"$bootstrap_bin/nvim" <<'EOF'
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
chmod +x "$bootstrap_bin/mise" "$bootstrap_bin/nvim"

# No npm stub here: npm is a runtime mise owns, reached through its shim like
# the rest, and an npm on the PATH every login inherits is exactly the non-mise
# copy the verifier's non-interactive login probe reports.

rm -- "$bootstrap_bin/zsh"
# MOCK_LOGIN_PATH_PREFIX models a directory a real login would put ahead of
# the mise shims, such as a dnf package's /usr/bin copy of a runtime.
# MOCK_SYSTEM_PATH_PREFIX models what WSL itself prepends before any of this
# repository's Zsh configuration runs, which is what "zsh -f" (no rc files)
# samples: it is deliberately not part of the sanitized login PATH above.
cat >"$bootstrap_bin/zsh" <<'EOF'
#!/usr/bin/env bash
printf '\033[H\033[2J\033[3J'
system_path="${MOCK_SYSTEM_PATH_PREFIX:+$MOCK_SYSTEM_PATH_PREFIX:}$PATH"
PATH="${MOCK_LOGIN_PATH_PREFIX:+$MOCK_LOGIN_PATH_PREFIX:}$XDG_DATA_HOME/mise/shims:$HOME/.local/bin:$PATH"
if [[ "$*" == *'login-path:'* ]]; then
  # The verifier asks both logins for their PATH through this marker, and the
  # two differ the way the real ones do: mise is activated in .zshrc, so only
  # the interactive login puts mise first. The other gets .zshenv's
  # ~/.local/bin ahead of the PATH it inherited from the verifier, which is
  # why the verifier has to start it from the PATH it was itself started with
  # rather than one it has already put the shims into (issue #507, V4-11), and
  # the shims behind ~/.local/bin only when the zsh package's .zprofile, which
  # adds them, is in this home.
  if [[ "${1:-}" == -lc ]]; then
    login_shims=""
    if [[ -e "$XDG_CONFIG_HOME/zsh/.zprofile" && -d "$XDG_DATA_HOME/mise/shims" ]]; then
      login_shims="$XDG_DATA_HOME/mise/shims:"
    fi
    printf 'login-path:%s\n' \
      "${MOCK_LOGIN_PATH_PREFIX:+$MOCK_LOGIN_PATH_PREFIX:}$HOME/.local/bin:$login_shims$system_path"
  else
    printf 'login-path:%s\n' "$PATH"
  fi
elif [[ "$*" == *'__DOTFILES_VERIFY_SYSTEM_PATH__'* ]]; then
  printf '\n__DOTFILES_VERIFY_SYSTEM_PATH__%s\n' "$system_path"
elif [[ "$*" == *'__DOTFILES_VERIFY_PATH__'* ]]; then
  printf '\n__DOTFILES_VERIFY_PATH__%s\n' "$PATH"
elif [[ "$*" == *'__DOTFILES_VERIFY_STARSHIP__'* ]]; then
  printf '\n__DOTFILES_VERIFY_STARSHIP__%s\n' \
    "$XDG_CONFIG_HOME/starship/catppuccin-macchiato.toml"
elif [[ "$*" == *'command -v "$1"'* ]]; then
  command -v "${*: -1}" >/dev/null || exit 1
elif [[ "$*" == *'claude --version'* ]]; then
  claude --version >/dev/null || exit 1
elif [[ "$*" == *'login-env:'* ]]; then
  # A fresh login reads the stowed ~/.zshenv, so the answer has to come from the
  # file the installer actually deployed rather than from this fixture.
  # Extracting the exports is enough, and is all this stub can do: .zshenv is
  # Zsh and this is Bash.
  while IFS= read -r assignment; do
    export "${assignment%%=*}=${assignment#*=}"
  done < <(sed -n 's/^export \([A-Z_][A-Z_0-9]*=[^ ]*\)$/\1/p' "$HOME/.zshenv" 2>/dev/null)
  bash -c "${*: -1}"
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
  "CODEX_HOME=$bootstrap_home/.codex"
  "XDG_CONFIG_HOME=$bootstrap_config"
  "XDG_DATA_HOME=$bootstrap_data"
  # Simulate the original Noctty/Bash process: the eventual mise shim
  # directory (and therefore every AI binary) is absent.
  "PATH=$bootstrap_home/.local/bin:$bootstrap_bin:$PATH"
  "WSL_DISTRO_NAME=FedoraLinux"
  "OS_RELEASE_FILE=$test_root/os-release"
  "SHELL_STATE=$bootstrap_shell_state"
  "MOCK_EASY_DOTNET_DEBUGGER=$debugger_path"
  "BOOTSTRAP_COMMAND_LOG=$bootstrap_command_log"
  "TEST_STUB_ROOT=$bootstrap_stub_root"
  "WINDOWS_SYSTEM_ROOT=$windows_root"
  # The Noctty theme bridge is a named action with its own error boundary now
  # (issue #148): a PowerShell that cannot run is a reported failure, not a
  # silent no-op, so the mock needs its log destination here too.
  "POWERSHELL_LOG=$test_root/bootstrap-powershell.log"
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
grep -Fq 'dotnet is mise-managed via shim' "$test_root/bootstrap.log"
grep -Fq 'node is mise-managed via shim' "$test_root/bootstrap.log"

# A dnf copy of a mise-owned runtime ahead of the mise shims in the login PATH
# is Linux-native, so the Windows-path check alone accepted it. The verifier
# must now name it.
dnf_shadow="$test_root/dnf-shadow-bin"
mkdir -p "$dnf_shadow"
cp "$bootstrap_bin/mock-command" "$dnf_shadow/dotnet"
if "${bootstrap_environment[@]}" "MOCK_LOGIN_PATH_PREFIX=$dnf_shadow" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/dnf-shadow.log" 2>&1; then
  printf 'Fedora WSL verification accepted a non-mise dotnet ahead of the mise shim.\n' >&2
  exit 1
fi
grep -Fq "dotnet resolves outside mise in the configured login PATH: $dnf_shadow/dotnet" \
  "$test_root/dnf-shadow.log"
if grep -Fq 'node resolves outside mise' "$test_root/dnf-shadow.log"; then
  printf 'The dotnet shadow fixture unexpectedly failed an unrelated runtime.\n' >&2
  exit 1
fi
printf 'PASS: Fedora WSL verification rejects a non-mise runtime shadowing the mise shim\n'

# The same dnf copy placed where dnf actually puts it: on the PATH every login
# inherits, behind the shims the interactive login adds. This verifier never
# asked a login that is not interactive before #507 (V4-11). Asked from its own
# PATH, after it had added the shims to it, the login would inherit them ahead
# of the copy and pass; asked from the PATH it was started with, it runs the
# copy unless the zsh package's .zprofile puts the shims ahead of it.
if grep -Fq 'runs a copy of' "$test_root/bootstrap.log"; then
  printf 'Fedora WSL verification could not ask a non-interactive login on a healthy machine:\n' >&2
  grep -F 'runs a copy of' "$test_root/bootstrap.log" >&2
  exit 1
fi
dnf_system="$test_root/dnf-system-bin"
mkdir -p "$dnf_system"
cp "$bootstrap_bin/mock-command" "$dnf_system/node"
# As bootstrapped, with .zprofile linked: the login runs the shim, and the
# machine verifies. This is every real machine's shape, since dnf's runtimes
# are always in /usr/bin.
if ! "${bootstrap_environment[@]}" \
  "PATH=$bootstrap_home/.local/bin:$bootstrap_bin:$dnf_system:$PATH" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/dnf-behind-shims.log" 2>&1; then
  cat "$test_root/dnf-behind-shims.log" >&2
  printf 'Fedora WSL verification failed a dnf node that the login shims shadow.\n' >&2
  exit 1
fi
if grep -Fq 'resolves outside mise' "$test_root/dnf-behind-shims.log"; then
  printf 'Fedora WSL verification reported a dnf node that .zprofile puts behind the shims.\n' >&2
  exit 1
fi
grep -Fq "$bootstrap_config/zsh/.zprofile -> $(realpath "$repo_root/zsh/.config/zsh/.zprofile")" \
  "$test_root/dnf-behind-shims.log"
printf 'PASS: Fedora WSL verification accepts a dnf runtime that the login shims put mise ahead of\n'

# Without .zprofile, as on a machine stowed before the file existed: that
# login runs the dnf copy, and the missing link and the copy are both
# reported, the second naming the repair.
mv "$bootstrap_config/zsh/.zprofile" "$test_root/withheld-zprofile"
if "${bootstrap_environment[@]}" \
  "PATH=$bootstrap_home/.local/bin:$bootstrap_bin:$dnf_system:$PATH" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/dnf-system.log" 2>&1; then
  printf 'Fedora WSL verification accepted a dnf node that a non-interactive login runs.\n' >&2
  exit 1
fi
mv "$test_root/withheld-zprofile" "$bootstrap_config/zsh/.zprofile"
grep -Fq "$bootstrap_config/zsh/.zprofile is missing" "$test_root/dnf-system.log"
grep -Fq "node resolves outside mise in a login that is not interactive: $dnf_system/node" \
  "$test_root/dnf-system.log"
grep -Fq 'restow the zsh package so that file is linked' "$test_root/dnf-system.log"
if grep -Fq 'node resolves outside mise in the configured login PATH' "$test_root/dnf-system.log"; then
  printf 'The interactive probe caught the dnf copy, so this case proves nothing about the other.\n' >&2
  exit 1
fi
rm -r -- "$dnf_system"
printf 'PASS: Fedora WSL verification reports a dnf runtime a non-interactive login runs instead of mise\n'

# /etc/wsl.conf's [interop] appendWindowsPath=false is what keeps Windows
# directories out of PATH in every context that is not an interactive Zsh
# login: systemd units, "wsl.exe -e", VS Code's integrated shell, cron. A file
# that configure-interop.sh has not reached (or that a WSL restart has not been
# applied to) leaves all of those inheriting the Windows PATH, and nothing in
# the login shell can reveal that. The verifier must read the file itself.
missing_append_conf="$test_root/wsl-conf-without-append.conf"
printf '[boot]\nsystemd=true\n\n[interop]\nenabled=true\n' >"$missing_append_conf"
if "${bootstrap_environment[@]}" "WSL_CONF_FILE=$missing_append_conf" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/wsl-conf-missing-append.log" 2>&1; then
  printf 'Fedora WSL verification accepted a wsl.conf without appendWindowsPath=false.\n' >&2
  exit 1
fi
grep -Fq "$missing_append_conf does not set [interop] appendWindowsPath=false" \
  "$test_root/wsl-conf-missing-append.log"
# The unrelated [boot] section must not be what the check keyed on.
grep -Fq 'configure-interop.sh' "$test_root/wsl-conf-missing-append.log"
printf 'PASS: Fedora WSL verification rejects a wsl.conf without [interop] appendWindowsPath=false\n'

# A wsl.conf this repository did not write may spell the key with spaces, and
# WSL reads that as false. Comparing the file against the rendered form would
# report a correctly configured machine as unconfigured, so the check reads the
# value instead.
spaced_append_conf="$test_root/wsl-conf-spaced-append.conf"
printf '[boot]\nsystemd=true\n\n[interop]\nenabled=true\n  appendWindowsPath = false\n' \
  >"$spaced_append_conf"
if ! "${bootstrap_environment[@]}" "WSL_CONF_FILE=$spaced_append_conf" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/wsl-conf-spaced-append.log" 2>&1; then
  printf 'Fedora WSL verification rejected a wsl.conf that sets appendWindowsPath with spaces:\n' >&2
  sed -n '1,120p' "$test_root/wsl-conf-spaced-append.log" >&2
  exit 1
fi
grep -Fq "$spaced_append_conf sets [interop] appendWindowsPath=false" \
  "$test_root/wsl-conf-spaced-append.log"
printf 'PASS: Fedora WSL verification accepts the spaced "appendWindowsPath = false" form\n'

# The opposite of absent: the key is there and switched on. The failure has to
# name the value it found, not claim the key is missing.
enabled_append_conf="$test_root/wsl-conf-append-true.conf"
printf '[interop]\nenabled=true\nappendWindowsPath=true\n' >"$enabled_append_conf"
if "${bootstrap_environment[@]}" "WSL_CONF_FILE=$enabled_append_conf" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/wsl-conf-append-true.log" 2>&1; then
  printf 'Fedora WSL verification accepted a wsl.conf with appendWindowsPath=true.\n' >&2
  exit 1
fi
grep -Fq "$enabled_append_conf sets [interop] appendWindowsPath=true" \
  "$test_root/wsl-conf-append-true.log"
printf 'PASS: Fedora WSL verification names the value when appendWindowsPath is on\n'

# With the wsl.conf policy in place but WSL still injecting Windows entries
# (the file was written and never applied by "wsl --shutdown"), the sanitized
# login PATH looks perfect -- the Zsh stripper removed the entry before the
# verifier could see it. The unsanitized sample is what observes it, and it
# must name the entry.
injected_windows_entry="/mnt/c/Windows/System32"
if "${bootstrap_environment[@]}" \
  "MOCK_SYSTEM_PATH_PREFIX=$injected_windows_entry" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/windows-path-injected.log" 2>&1; then
  printf 'Fedora WSL verification accepted a Windows entry in the unsanitized PATH.\n' >&2
  exit 1
fi
grep -Fq \
  "The unsanitized system PATH contains a Windows entry: $injected_windows_entry" \
  "$test_root/windows-path-injected.log"
if grep -Fq 'does not set [interop] appendWindowsPath=false' \
  "$test_root/windows-path-injected.log"; then
  printf 'The injected-PATH fixture unexpectedly failed the wsl.conf check too.\n' >&2
  exit 1
fi
# The sanitized check passed in the same run: on its own it cannot see this.
grep -Fq 'The Zsh PATH sanitizer leaves only Linux filesystem entries' \
  "$test_root/windows-path-injected.log"
printf 'PASS: Fedora WSL verification rejects a Windows entry the Zsh sanitizer hides\n'

wsl_tmux_plugin="$bootstrap_data/tmux/plugins/catppuccin"
rm -f -- "$wsl_tmux_plugin/catppuccin.tmux"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/tmux-missing.log" 2>&1; then
  printf 'Fedora WSL verification accepted a missing Catppuccin tmux plugin.\n' >&2
  exit 1
fi
grep -Fq 'Catppuccin tmux is missing' "$test_root/tmux-missing.log"
git -C "$wsl_tmux_plugin" checkout -q -- catppuccin.tmux
printf 'PASS: Fedora WSL verification rejects a missing Catppuccin tmux plugin\n'

git -C "$wsl_tmux_plugin" -c user.name=WSL-Test -c user.email=wsl@example.invalid \
  commit -q --allow-empty -m 'past the pin'
if ! "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/tmux-drift.log" 2>&1; then
  printf 'Fedora WSL verification failed a Catppuccin tmux checkout past the pin:\n' >&2
  cat "$test_root/tmux-drift.log" >&2
  exit 1
fi
grep -Fq 'Catppuccin tmux is at v2.3.0-1-g' "$test_root/tmux-drift.log"
grep -Fq 'not the pinned v2.3.0' "$test_root/tmux-drift.log"
git -C "$wsl_tmux_plugin" checkout -q --detach v2.3.0
printf 'PASS: Fedora WSL verification warns about a Catppuccin tmux checkout past the pin\n'

# The two questions #371 added to this verifier, asserted on the run above,
# which is the only one here that has to succeed. This guest had no Neovim
# start at all before, so both lines are new evidence and both have to appear.
grep -Fq 'Lazy plugins match ' "$test_root/tmux-drift.log"
grep -Fq 'Neovim starts and reports >= ' "$test_root/tmux-drift.log"
printf 'PASS: Fedora WSL verification reports Lazy plugin state and a bounded Neovim start\n'

# Negative control for the pair: the tree is read, not repaired.
wsl_withheld_plugin="$(jq -r 'keys[0]' "$bootstrap_config/nvim/lazy-lock.json")"
mv "$bootstrap_data/nvim/lazy/$wsl_withheld_plugin" "$test_root/withheld-plugin"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/lazy-missing.log" 2>&1; then
  printf 'Fedora WSL verification accepted a locked plugin that is not installed\n' >&2
  exit 1
fi
grep -Fq "Lazy plugin not installed: $wsl_withheld_plugin" "$test_root/lazy-missing.log"
mv "$test_root/withheld-plugin" "$bootstrap_data/nvim/lazy/$wsl_withheld_plugin"
printf 'PASS: Fedora WSL verification reports a locked plugin the tree is missing\n'

# A checkout at the locked commit with no preview server is what a headless
# install whose build never finished left behind.
grep -Fq 'Markdown preview server: ' "$test_root/tmux-drift.log"
wsl_preview_server="$bootstrap_data/nvim/lazy/markdown-preview.nvim/app/bin/$(bash -c 'source "$1/common/lib/markdown-preview.sh" && markdown_preview_server_name' _ "$repo_root")"
mv "$wsl_preview_server" "$test_root/withheld-preview-server"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/preview-missing.log" 2>&1; then
  printf 'Fedora WSL verification accepted a Markdown preview with no server\n' >&2
  exit 1
fi
grep -Fq 'Markdown preview server absent: ' "$test_root/preview-missing.log"
mv "$test_root/withheld-preview-server" "$wsl_preview_server"
printf 'PASS: Fedora WSL verification reports a Markdown preview with no server\n'

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

run_bootstrap --ai
grep -Fq 'AI profile verification passed' "$test_root/bootstrap.log"
grep -Fq 'Fresh Zsh login resolves claude' "$test_root/bootstrap.log"
grep -Fq 'Fresh Zsh login resolves herdr' "$test_root/bootstrap.log"
grep -Fq 'Claude Code starts in a fresh Zsh login' "$test_root/bootstrap.log"
[[ -x "$bootstrap_data/mise/shims/claude" ]]
[[ -x "$bootstrap_data/mise/shims/herdr" ]]

[[ "$(sha256sum "$bootstrap_config/git/local")" == "$bootstrap_identity" ]]
[[ "$(sha256sum "$bootstrap_home/notes")" == "$bootstrap_notes" ]]
[[ -L "$bootstrap_home/.zshenv" ]]
[[ -L "$bootstrap_config/zsh/platform-env.zsh" ]]
[[ ! -e "$bootstrap_config/ghostty/config" ]]
grep -Fqx "$bootstrap_bin/zsh" "$bootstrap_shell_state"

printf 'Fedora WSL platform composition, safety and idempotency tests passed.\n'

# ---------------------------------------------------------------------------
# A Linux-spelled shim that resolves to a Windows executable (issue #396,
# GAP-11)
#
# command -v answers with the first PATH hop and does not follow symlinks, so
# asking is_windows_path about that spelling said nothing about where the
# command ends up. bat is one of the names the verifier probes, and probing
# runs it -- through WSL interop, on a machine the verifier has just called
# Linux-native.
# ---------------------------------------------------------------------------

windows_shim_dir="$test_root/windows-shim"
mkdir -p "$windows_shim_dir"
cp "$bootstrap_bin/mock-command" "$windows_shim_dir/bat.exe"
ln -s bat.exe "$windows_shim_dir/bat"
# The LaTeX toolchain is checked for resolution only, so the same shim there is
# refused without being run. Every run with --latex otherwise had the whole
# toolchain present, and that loop had never been seen to fail.
cp "$bootstrap_bin/mock-command" "$windows_shim_dir/pdflatex.exe"
ln -s pdflatex.exe "$windows_shim_dir/pdflatex"

if "${bootstrap_environment[@]}" \
  "PATH=$windows_shim_dir:$bootstrap_home/.local/bin:$bootstrap_bin:$PATH" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" --latex \
  >"$test_root/windows-shim.log" 2>&1; then
  printf 'Fedora WSL verification accepted a shim resolving to a Windows executable.\n' >&2
  exit 1
fi
grep -Fq "bat resolves to a Windows executable: $windows_shim_dir/bat.exe" \
  "$test_root/windows-shim.log"
if grep -Fq "bat runs: $windows_shim_dir/bat" "$test_root/windows-shim.log"; then
  printf 'Fedora WSL verification reported a Windows shim as a working Linux command.\n' >&2
  exit 1
fi
# The verifier names the canonical target, so the expectation is canonical too.
windows_shim_log="$(cat "$test_root/windows-shim.log")"
assert_contains "$windows_shim_log" \
  "pdflatex resolves to a Windows executable: $(realpath "$windows_shim_dir/pdflatex.exe")"
assert_not_contains "$windows_shim_log" "pdflatex: $windows_shim_dir/pdflatex"
# The rest of the toolchain still resolves, so the loop was reached and judged
# each command on its own.
assert_contains "$windows_shim_log" "xelatex: $bootstrap_bin/xelatex"
printf 'PASS: Fedora WSL verification refuses a Linux-spelled shim that resolves to a .exe\n'

# The same question asked of the AI commands, which report "is Linux-native"
# in so many words and so must mean the resolved target.
ai_shim_dir="$test_root/windows-ai-shim"
mkdir -p "$ai_shim_dir"
cp "$bootstrap_bin/mock-command" "$ai_shim_dir/claude.exe"
ln -s claude.exe "$ai_shim_dir/claude"
# The verifier puts mise's shims at the front of PATH itself, so the shim has
# to be the only claude there is for this question to reach the loop at all.
mv "$bootstrap_data/mise/shims/claude" "$test_root/claude-shim-aside"
"${bootstrap_environment[@]}" \
  "PATH=$ai_shim_dir:$bootstrap_home/.local/bin:$bootstrap_bin:$PATH" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/windows-ai-shim.log" 2>&1 ||
  : # The fixture fails for other reasons too; the lines below are the assertion.
mv "$test_root/claude-shim-aside" "$bootstrap_data/mise/shims/claude"
if grep -Fq "claude is Linux-native: $ai_shim_dir/claude" \
  "$test_root/windows-ai-shim.log"; then
  printf 'Fedora WSL verification called a .exe shim Linux-native.\n' >&2
  exit 1
fi
grep -Fq "claude resolves to a Windows executable: $ai_shim_dir/claude.exe" \
  "$test_root/windows-ai-shim.log"
printf 'PASS: "is Linux-native" is a claim about the resolved target, not the spelling\n'

# ---------------------------------------------------------------------------
# The OCaml line reports what the sub-verifier established (issue #396, GAP-07)
#
# common/verify-ocaml.sh exits 0 for three different worlds, one of which is
# "not selected and not installed". ocaml is disabled for fedora-wsl, so that
# is the world a stock machine is in, and the caller used to answer it with a
# green line claiming the compiler starts.
# ---------------------------------------------------------------------------

grep -Fq 'OCaml profile is not selected and not installed (not applicable)' \
  "$test_root/bootstrap.log" ||
  {
    printf 'The Fedora WSL fixture did not reach the unselected OCaml world.\n' >&2
    exit 1
  }
if grep -Fq 'OCaml compiler and Platform tools start inside WSL' \
  "$test_root/bootstrap.log"; then
  printf 'Fedora WSL verification claims the OCaml compiler starts on a machine that never selected it.\n' >&2
  exit 1
fi
grep -Fq 'OCaml profile verification completed' "$test_root/bootstrap.log"
printf 'PASS: the OCaml line reports what the sub-verifier established, not one of its three worlds\n'

# ---------------------------------------------------------------------------
# Every Stow link is checked against the exact file Stow should have linked
# (issue #369)
#
# The containment guarantee alone accepted a link redirected at any other file
# in the same package. Each call site now names its source; these two cases ask
# whether the names are real and whether the guarantee is live.
# ---------------------------------------------------------------------------

wsl_verifier="$repo_root/platforms/fedora-wsl/scripts/verify.sh"
mapfile -t wsl_symlink_calls < <(
  awk '
    { line = line $0 }
    /\\$/ { sub(/\\$/, " ", line); next }
    { print line; line = "" }
  ' "$wsl_verifier" |
    grep -E '^[[:space:]]*check_symlink ' | sed 's/^[[:space:]]*//'
)
((${#wsl_symlink_calls[@]} > 0)) || {
  printf 'No check_symlink call was read out of the Fedora WSL verifier.\n' >&2
  exit 1
}

wsl_checked_sources=0
for wsl_call in "${wsl_symlink_calls[@]}"; do
  mapfile -t wsl_call_arguments < <(
    (
      # Read by the eval below, which is the call's own source text.
      # shellcheck disable=SC2034
      DOTFILES_ROOT="$repo_root"
      # The link side names a machine, not this checkout.
      HOME="/nonexistent-fixture-home"
      # shellcheck disable=SC2034
      XDG_CONFIG_HOME="$HOME/.config"
      eval "set -- $wsl_call"
      shift
      printf '%s\n' "$@"
    )
  )
  ((${#wsl_call_arguments[@]} == 3)) || {
    printf 'check_symlink names no Stow source, so it can only prove containment: %s\n' \
      "$wsl_call" >&2
    exit 1
  }
  wsl_expected_root="${wsl_call_arguments[1]%/}"
  wsl_expected_source="${wsl_call_arguments[2]}"
  [[ -e "$wsl_expected_source" ]] || {
    printf 'check_symlink names a Stow source this checkout does not have: %s\n' \
      "$wsl_expected_source" >&2
    exit 1
  }
  [[ "$wsl_expected_source" == "$wsl_expected_root/"* ]] || {
    printf 'check_symlink names a source outside the package it declares: %s\n' \
      "$wsl_expected_source" >&2
    exit 1
  }
  wsl_checked_sources=$((wsl_checked_sources + 1))
done
printf 'PASS: all %d Stow sources the Fedora WSL verifier names exist under the package it declares\n' \
  "$wsl_checked_sources"

# And the guarantee is live: the deployed link is repointed at another file in
# the same package, which containment alone accepted.
mislinked="$bootstrap_config/zsh/platform.zsh"
ln -sfn \
  "$repo_root/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform-env.zsh" \
  "$mislinked"
if "${bootstrap_environment[@]}" \
  "$repo_root/platforms/fedora-wsl/scripts/verify.sh" \
  >"$test_root/mislinked.log" 2>&1; then
  printf 'Fedora WSL verification accepted a link at the wrong file in the right package.\n' >&2
  exit 1
fi
grep -Fq 'is not the file Stow should have linked' "$test_root/mislinked.log"
grep -Fq "$repo_root/platforms/fedora-wsl/stow/zsh-platform/.config/zsh/platform.zsh" \
  "$test_root/mislinked.log"
printf 'PASS: a link into the right package but at the wrong file fails verification\n'
