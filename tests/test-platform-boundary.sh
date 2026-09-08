#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

portable_packages=(
  bat bin fzf ghostty git lazygit mise nvim-lazyvim starship tmux zsh
)

for package in "${portable_packages[@]}"; do
  [[ -d "$repo_root/$package" ]] || {
    printf 'Portable Stow package is missing: %s\n' "$package" >&2
    exit 1
  }
done

if grep -R -E -n \
  '/usr/share|readlink -f|\b(dnf|rpm|systemctl|swaymsg|lookandfeeltool)\b' \
  "${portable_packages[@]/#/$repo_root/}"; then
  printf 'Portable Stow packages contain Fedora-specific integration.\n' >&2
  exit 1
fi

if grep -E -n '\b(dnf|rpm)\b' \
  "$repo_root/common/install-ocaml.sh" \
  "$repo_root/common/verify-ocaml.sh"; then
  printf 'Portable OCaml scripts contain Fedora-specific package management.\n' >&2
  exit 1
fi

if grep -E -n '\b(dnf|rpm|systemctl|plasmashell|swaymsg|lookandfeeltool)\b' \
  "$repo_root/common/install-ai.sh" \
  "$repo_root/common/verify-ai.sh"; then
  printf 'Portable AI profile scripts contain Fedora/desktop-specific integration.\n' >&2
  exit 1
fi

grep -Fq 'zsh/platform.zsh' \
  "$repo_root/zsh/.config/zsh/.zshrc"
grep -Fq '/usr/share/zsh-autosuggestions' \
  "$repo_root/platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh"
grep -Fq '/opt/homebrew/share/zsh-autosuggestions' \
  "$repo_root/platforms/macos/stow/zsh-platform/.config/zsh/platform.zsh"

mock_bin="$test_root/bin"
stow_log="$test_root/stow.log"
mkdir -p "$mock_bin" "$test_root/home"

cat >"$mock_bin/stow" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >>"$STOW_LOG"
EOF
chmod +x "$mock_bin/stow"

run_stow() {
  HOME="$test_root/home" \
    PATH="$mock_bin:$PATH" \
    STOW_LOG="$stow_log" \
    "$@" >/dev/null
}

run_stow "$repo_root/common/stow.sh"

for package in "${portable_packages[@]}"; do
  grep -Fqx "$package" "$stow_log"
done

if grep -Eq '^(sway|waybar|zsh-platform|theme-hooks|theme-assets)$' "$stow_log"; then
  printf 'Portable Stow entry point deployed a Fedora package.\n' >&2
  exit 1
fi

: >"$stow_log"
run_stow "$repo_root/common/stow.sh" --headless

for package in "${portable_packages[@]}"; do
  if [[ "$package" == ghostty ]]; then
    if grep -Fqx "$package" "$stow_log"; then
      printf 'Headless common profile deployed Ghostty configuration.\n' >&2
      exit 1
    fi
  else
    grep -Fqx "$package" "$stow_log"
  fi
done

: >"$stow_log"
run_stow "$repo_root/platforms/fedora/scripts/stow.sh" --sway

for package in \
  "${portable_packages[@]}" zsh-platform theme-hooks theme-assets sway waybar; do
  grep -Fqx "$package" "$stow_log"
done

: >"$stow_log"
run_stow "$repo_root/platforms/macos/scripts/stow.sh"

for package in "${portable_packages[@]}" zsh-platform aerospace nvim-macos; do
  grep -Fqx "$package" "$stow_log"
done
if grep -Eq '^(sway|waybar|theme-hooks|theme-assets|nvim-wsl|interop)$' "$stow_log"; then
  printf 'macOS Stow entry point deployed a Fedora or WSL package.\n' >&2
  exit 1
fi

printf 'Portable, Fedora, and macOS ownership boundaries passed.\n'
