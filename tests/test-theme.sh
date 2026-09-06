#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

mock_bin="$test_root/bin"
sandbox_bin="$test_root/sandbox-bin"
mock_log="$test_root/mock.log"
mkdir -p "$mock_bin" "$sandbox_bin" "$test_root/home" "$test_root/xdg"
mkdir -p "$test_root/xdg/dotfiles/theme-hooks.d"
ln -s \
  "$repo_root/platforms/fedora/stow/theme-hooks/.config/dotfiles/theme-hooks.d/fedora.sh" \
  "$test_root/xdg/dotfiles/theme-hooks.d/fedora.sh"

cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--user is-active --quiet app-com.mitchellh.ghostty.service" ]]; then
  exit 1
fi
exit 0
EOF
cat >"$mock_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-x ghostty" ]]; then
  exit 0
fi
exit 1
EOF
cat >"$mock_bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat >"$mock_bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MOCK_LOG"
EOF

for command in bash basename cat chmod dirname mkdir mktemp mv readlink; do
  ln -s "$(command -v "$command")" "$sandbox_bin/$command"
done

chmod +x "$mock_bin"/*

HOME="$test_root/home" \
XDG_CONFIG_HOME="$test_root/xdg" \
XDG_DATA_HOME="$test_root/home/.local/share" \
PATH="$mock_bin:$sandbox_bin" \
MOCK_LOG="$mock_log" \
  "$repo_root/bin/.local/bin/theme" mocha >/dev/null

grep -Fqx -- '-USR2 -x ghostty' "$mock_log"
grep -Fqx 'theme = catppuccin-mocha.conf' \
  "$test_root/xdg/dotfiles/ghostty.conf"

printf 'Ghostty direct-process theme reload test passed.\n'
