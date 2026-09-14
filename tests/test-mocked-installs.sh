#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/test.sh
source "$repo_root/tests/lib/test.sh"

test_install_cleanup_trap
test_new_root
test_root="$TEST_ROOT"

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
shell_state="$test_root/login-shell"
mkdir -p "$test_root/dmi"
printf '/bin/bash\n' >"$shell_state"
: >"$command_log"

cat >"$mock_bin/dnf" <<'EOF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$mock_bin/rpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -q && "$2" == terra-release ]]; then
  exit 0
fi
exit 1
EOF
cat >"$mock_bin/mokutil" <<'EOF'
#!/usr/bin/env bash
printf 'SecureBoot disabled\n'
EOF
cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'is-enabled asusd.service') printf 'static\n' ;;
  'cat asus-shutdown.service') exit 0 ;;
  'is-enabled power-profiles-daemon.service') printf 'enabled\n' ;;
  'is-enabled tuned-ppd.service') printf 'not-found\n'; exit 1 ;;
  'is-enabled tuned.service') printf 'masked\n'; exit 1 ;;
  'is-active --quiet') exit 1 ;;
  *) exit 0 ;;
esac
EOF
cat >"$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$COMMAND_LOG"
case "${1:-}" in
usermod)
  if [[ "${2:-}" == --shell && $# -eq 4 ]]; then
    printf '%s\n' "$3" >"$SHELL_STATE"
    exit 0
  fi
  ;;
dnf | install | systemctl)
  exit 0
  ;;
esac
printf 'strict sudo fixture rejected unsupported argv: %s\n' "$*" >&2
exit 96
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
cat >"$mock_bin/asusctl" <<'EOF'
#!/usr/bin/env bash
printf 'asusctl %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF
chmod +x "$mock_bin"/*

printf 'ID=fedora\n' >"$test_root/os-release"
printf 'GA402RK\n' >"$test_root/dmi/board_name"
printf 'ROG Zephyrus G14\n' >"$test_root/dmi/product_name"

mapfile -t base_environment < <(test_env_args "$test_root")
test_environment=(
  env
  "${base_environment[@]}"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "SHELL_STATE=$shell_state"
  "OS_RELEASE_FILE=$test_root/os-release"
  "DMI_ROOT=$test_root/dmi"
  "KERNEL_RELEASE=7.1.0-test"
)

"${test_environment[@]}" "$repo_root/scripts/install-system.sh" >/dev/null
"${test_environment[@]}" "$repo_root/scripts/install-system.sh" >/dev/null
"${test_environment[@]}" "$repo_root/scripts/install-terra.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-ocaml.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/platforms/fedora/scripts/install-latex.sh" >/dev/null
"${test_environment[@]}" "$repo_root/scripts/install-sway.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/scripts/install-asus-hardware.sh" \
  --model ga402rk --charge-limit 80 --non-interactive >/dev/null

assert_file_contains "$command_log" 'sudo dnf install -y bat curl eza'
assert_file_contains "$command_log" 'gh git git-delta jq libicu'
assert_file_contains "$command_log" 'neovim openssh-clients ripgrep'
assert_file_contains "$command_log" 'ShellCheck shadow-utils sqlite'
expected_zsh_path="$(PATH="$mock_bin:$PATH" command -v zsh)"
assert_file_contains "$command_log" "sudo usermod --shell $expected_zsh_path fedora-test"
assert_eq "$expected_zsh_path" "$(<"$shell_state")" 'login shell state'
assert_eq 1 "$(grep -Fc 'sudo usermod --shell ' "$command_log")" \
  'login shell should only be changed once'
assert_file_contains "$command_log" \
  'sudo dnf install -y --disablerepo=copr:copr.fedorainfracloud.org:jdxcode:mise ghostty mise starship'
assert_file_contains "$command_log" \
  'sudo dnf install -y bzip2 bubblewrap gcc gcc-c++ m4 make opam patch pkgconf-pkg-config unzip'
assert_file_contains "$command_log" \
  'sudo dnf install -y texlive-scheme-medium latexmk biber texlive-biblatex texlive-latexindent'
assert_file_contains "$command_log" \
  'sudo dnf install -y blueman brightnessctl cliphist dex-autostart fuzzel grim libnotify lxqt-policykit mako nm-connection-editor pavucontrol playerctl slurp sway swaybg swayidle swaylock sway-systemd swappy waybar wireplumber xdg-desktop-portal-gtk xdg-desktop-portal-wlr'
assert_file_contains "$command_log" 'nm-connection-editor'
assert_file_contains "$command_log" 'sudo install -Dm755'
assert_file_contains "$command_log" '/usr/local/bin/dotfiles-sway'
assert_file_contains "$command_log" '/usr/share/wayland-sessions/dotfiles-sway.desktop'
assert_file_contains "$command_log" 'sudo systemctl start asusd.service'
assert_file_contains "$command_log" \
  'sudo systemctl mask --now power-profiles-daemon.service'
assert_file_contains "$command_log" 'sudo dnf install -y amd-gpu-firmware'
assert_file_contains "$command_log" 'asusctl battery limit 80'
assert_file_line "$test_root/config/dotfiles/hardware.conf" 'profile=ga402rk'
assert_file_line "$test_root/config/dotfiles/hardware.conf" 'charge_limit=80'

first_state="$(sha256sum "$test_root/config/dotfiles/hardware.conf")"
"${test_environment[@]}" \
  "$repo_root/scripts/install-asus-hardware.sh" \
  --model ga402rk --charge-limit 80 --non-interactive >/dev/null
second_state="$(sha256sum "$test_root/config/dotfiles/hardware.conf")"
assert_eq "$first_state" "$second_state" 'hardware profile state changed on rerun'

printf 'Mocked package, service, and idempotent hardware flows passed.\n'
