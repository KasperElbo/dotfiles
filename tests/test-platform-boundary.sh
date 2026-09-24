#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/source-code.sh
source "$repo_root/tests/lib/source-code.sh"
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

for portable_script in common/install-ocaml.sh common/verify-ocaml.sh; do
  if code_grep -E -n '\b(dnf|rpm)\b' "$repo_root/$portable_script"; then
    printf 'Portable OCaml script %s contains Fedora-specific package management.\n' \
      "$portable_script" >&2
    exit 1
  fi
done

for portable_script in common/install-ai.sh common/verify-ai.sh; do
  if code_grep -E -n '\b(dnf|rpm|systemctl|plasmashell|swaymsg|lookandfeeltool)\b' \
    "$repo_root/$portable_script"; then
    printf 'Portable AI profile script %s contains Fedora/desktop-specific integration.\n' \
      "$portable_script" >&2
    exit 1
  fi
done

code_grep -Fq 'zsh/platform.zsh' \
  "$repo_root/zsh/.config/zsh/.zshrc"
code_grep -Fq '/usr/share/zsh-autosuggestions' \
  "$repo_root/platforms/fedora/stow/zsh-platform/.config/zsh/platform.zsh"
code_grep -Fq '/opt/homebrew/share/zsh-autosuggestions' \
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

for package in \
  "${portable_packages[@]}" zsh-platform aerospace nvim-macos ghostty-macos \
  theme-hooks theme-assets; do
  grep -Fqx "$package" "$stow_log"
done
# theme-hooks is a package name each platform fills with its own file, not a
# shared one, so macOS deploying it is not a boundary crossing. What would be
# is the file inside: platforms/macos/stow/theme-hooks holds macos.sh alone.
# theme-assets is genuinely shared and deployed from the repository root,
# which is the point of moving it there.
if grep -Eq '^(sway|waybar|nvim-wsl|interop)$' "$stow_log"; then
  printf 'macOS Stow entry point deployed a Fedora or WSL package.\n' >&2
  exit 1
fi
macos_hooks="$(
  find "$repo_root/platforms/macos/stow/theme-hooks" -name '*.sh' -printf '%f\n' | sort
)"
[[ "$macos_hooks" == "macos.sh" ]] || {
  printf 'The macOS theme-hooks package holds more than its own hook:\n%s\n' \
    "$macos_hooks" >&2
  exit 1
}

# --- A shared asset has one copy, and one place it lives -------------------

# The wallpapers were a Fedora-owned package, which is why a second platform
# wanting flavour-matched wallpapers would have grown a second set. They are
# shared now, and the thing that must not come back is the duplicate: a copy
# cropped or re-encoded for another platform would lose the pinned provenance
# the collection's README records.
for flavour in latte frappe macchiato mocha; do
  for variant in "" -lock; do
    copies="$(
      git -C "$repo_root" ls-files -- "*catppuccin-${flavour}${variant}.webp" | wc -l
    )"
    [[ "$copies" -eq 1 ]] || {
      printf 'Expected exactly one catppuccin-%s%s.webp, found %s:\n' \
        "$flavour" "$variant" "$copies" >&2
      git -C "$repo_root" ls-files -- "*catppuccin-${flavour}${variant}.webp" >&2
      exit 1
    }
  done
done
tracked_outside="$(
  git -C "$repo_root" ls-files -- '*wallpapers/*.webp' | grep -v '^theme-assets/' || true
)"
[[ -z "$tracked_outside" ]] || {
  printf 'Wallpapers live outside the shared package:\n%s\n' "$tracked_outside" >&2
  exit 1
}
printf 'PASS: one copy of each wallpaper, all in the shared package\n'

# Where a package lives is one rule, resolved rather than assumed, because the
# installer's preflight and the platform Stow script must agree about which
# copy a machine gets. A disagreement is a conflict reported against a
# directory nothing stows from.
resolve_root() {
  DOTFILES_ROOT="$repo_root" bash -c '
    source "$1/common/lib/capabilities.sh"
    capability_stow_package_root "$2" "$3"
  ' _ "$repo_root" "$@"
}
[[ "$(resolve_root fedora theme-assets)" == "$repo_root" ]] || {
  printf 'The shared package does not resolve to the repository root.\n' >&2
  exit 1
}
[[ "$(resolve_root fedora theme-hooks)" == "$repo_root/platforms/fedora/stow" ]] || {
  printf 'A Fedora-owned package no longer resolves to the Fedora tree.\n' >&2
  exit 1
}
printf 'PASS: shared and platform packages resolve to the tree that holds them\n'

printf 'Portable, Fedora, and macOS ownership boundaries passed.\n'
