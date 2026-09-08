#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

mode="apply"
dry_run="false"

usage() {
  cat <<'EOF'
Usage: apply-defaults.sh [--restore] [--dry-run]

Apply the small, documented macOS defaults set. --restore deletes only the
keys managed by this script so macOS can use its defaults again.
EOF
}

while (($#)); do
  case "$1" in
  --restore) mode="restore" ;;
  --dry-run) dry_run="true" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1" ;;
  esac
  shift
done

if [[ "$dry_run" != true ]]; then
  require_apple_silicon_macos
  require_command defaults
fi

managed_defaults=(
  'com.apple.dock|orientation|string|bottom'
  'com.apple.dock|tilesize|int|40'
  'com.apple.dock|autohide|bool|true'
  'com.apple.dock|show-recents|bool|false'
  'com.apple.dock|mru-spaces|bool|false'
  'NSGlobalDomain|AppleShowAllExtensions|bool|true'
  'com.apple.finder|AppleShowAllFiles|bool|true'
  'com.apple.finder|ShowPathbar|bool|true'
  'com.apple.finder|ShowStatusBar|bool|true'
  'com.apple.screencapture|location|string|__SCREENSHOT_DIRECTORY__'
  'com.apple.screencapture|type|string|png'
  'NSGlobalDomain|KeyRepeat|int|2'
  'NSGlobalDomain|InitialKeyRepeat|int|15'
)

screenshot_directory="$HOME/Pictures/Screenshots"

if [[ "$mode" == apply ]]; then
  info "Applying conservative macOS defaults"
  [[ "$dry_run" == true ]] || ensure_dir "$screenshot_directory"
else
  info "Restoring system behavior for managed macOS defaults"
fi

for item in "${managed_defaults[@]}"; do
  IFS='|' read -r domain key value_type value <<<"$item"
  [[ "$value" != __SCREENSHOT_DIRECTORY__ ]] || value="$screenshot_directory"

  if [[ "$mode" == apply ]]; then
    if [[ "$dry_run" == true ]]; then
      printf 'defaults write %q %q -%s %q\n' "$domain" "$key" "$value_type" "$value"
    else
      defaults write "$domain" "$key" "-$value_type" "$value"
    fi
  elif [[ "$dry_run" == true ]]; then
    printf 'defaults delete %q %q\n' "$domain" "$key"
  else
    defaults delete "$domain" "$key" >/dev/null 2>&1 || true
  fi
done

if [[ "$dry_run" == true ]]; then
  printf 'Restart Dock, Finder, and SystemUIServer\n'
else
  killall Dock Finder SystemUIServer >/dev/null 2>&1 || true
fi

success "macOS defaults ${mode} completed"
