#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
command_log="$test_root/commands.log"
mkdir -p "$mock_bin" "$test_root/home" "$test_root/xdg" "$test_root/dmi"

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

test_environment=(
  env
  "HOME=$test_root/home"
  "XDG_CONFIG_HOME=$test_root/xdg"
  "XDG_DATA_HOME=$test_root/home/.local/share"
  "PATH=$mock_bin:$PATH"
  "COMMAND_LOG=$command_log"
  "OS_RELEASE_FILE=$test_root/os-release"
  "DMI_ROOT=$test_root/dmi"
  "KERNEL_RELEASE=7.1.0-test"
)

"${test_environment[@]}" "$repo_root/scripts/install-system.sh" >/dev/null
"${test_environment[@]}" "$repo_root/scripts/install-terra.sh" >/dev/null
"${test_environment[@]}" "$repo_root/scripts/install-sway.sh" >/dev/null
"${test_environment[@]}" \
  "$repo_root/scripts/install-asus-hardware.sh" \
  --model ga402rk --charge-limit 80 --non-interactive >/dev/null

grep -Fq 'sudo dnf install -y bat curl eza' "$command_log"
grep -Fq 'sudo dnf install -y ghostty mise starship' "$command_log"
grep -Fq \
  'sudo dnf install -y blueman brightnessctl cliphist dex-autostart fuzzel grim jq libnotify lxqt-policykit mako nm-connection-editor pavucontrol playerctl slurp sway swaybg swayidle swaylock sway-systemd swappy waybar wireplumber xdg-desktop-portal-gtk xdg-desktop-portal-wlr' \
  "$command_log"
grep -Fq 'nm-connection-editor' "$command_log"
grep -Fq \
  'sudo install -Dm755' "$command_log"
grep -Fq \
  '/usr/local/bin/dotfiles-sway' "$command_log"
grep -Fq \
  '/usr/share/wayland-sessions/dotfiles-sway.desktop' "$command_log"
grep -Fq 'sudo systemctl start asusd.service' "$command_log"
grep -Fq \
  'sudo systemctl mask --now power-profiles-daemon.service' "$command_log"
grep -Fq 'sudo dnf install -y amd-gpu-firmware' "$command_log"
grep -Fq 'asusctl battery limit 80' "$command_log"
grep -Fqx profile=ga402rk "$test_root/xdg/dotfiles/hardware.conf"
grep -Fqx charge_limit=80 "$test_root/xdg/dotfiles/hardware.conf"

first_state="$(sha256sum "$test_root/xdg/dotfiles/hardware.conf")"
"${test_environment[@]}" \
  "$repo_root/scripts/install-asus-hardware.sh" \
  --model ga402rk --charge-limit 80 --non-interactive >/dev/null
second_state="$(sha256sum "$test_root/xdg/dotfiles/hardware.conf")"
[[ "$first_state" == "$second_state" ]]

printf 'Mocked package, service, and idempotent hardware flows passed.\n'
