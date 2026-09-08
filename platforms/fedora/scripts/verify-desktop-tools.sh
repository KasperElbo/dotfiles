#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"

failures=0
warnings=0

pass() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m✗\033[0m %s\n' "$*" >&2
  failures=$((failures + 1))
}

warning() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "$command_name: $(command -v "$command_name")"
  else
    fail "$command_name not found"
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# mimetype:desktop-file pairs this profile intentionally sets a default for.
mime_defaults=(
  "image/jpeg:org.kde.gwenview.desktop"
  "image/png:org.kde.gwenview.desktop"
  "image/gif:org.kde.gwenview.desktop"
  "image/bmp:org.kde.gwenview.desktop"
  "image/webp:org.kde.gwenview.desktop"
  "image/tiff:org.kde.gwenview.desktop"
  "application/pdf:org.kde.okular.desktop"
  "application/zip:org.kde.ark.desktop"
  "application/x-7z-compressed:org.kde.ark.desktop"
  "application/vnd.rar:org.kde.ark.desktop"
  "application/x-tar:org.kde.ark.desktop"
  "application/x-compressed-tar:org.kde.ark.desktop"
  "application/x-bzip-compressed-tar:org.kde.ark.desktop"
  "application/x-xz-compressed-tar:org.kde.ark.desktop"
  "video/mp4:mpv.desktop"
  "video/x-matroska:mpv.desktop"
  "video/webm:mpv.desktop"
  "video/x-msvideo:mpv.desktop"
  "video/quicktime:mpv.desktop"
  "audio/mpeg:mpv.desktop"
  "audio/flac:mpv.desktop"
  "audio/ogg:mpv.desktop"
  "audio/x-wav:mpv.desktop"
)

section "Desktop-tools commands"

for command_name in ark gwenview okular gimp pdfarranger mpv skanpage xdg-mime; do
  check_command "$command_name"
done

section "Default applications"

for mapping in "${mime_defaults[@]}"; do
  mime="${mapping%%:*}"
  expected="${mapping#*:}"
  current="$(xdg-mime query default "$mime" 2>/dev/null || true)"

  if [[ "$current" == "$expected" ]]; then
    pass "$mime -> $expected"
  elif [[ -z "$current" ]]; then
    warning "$mime has no default application set"
  else
    warning "$mime default is $current (an existing user choice was kept)"
  fi
done

printf '\n'

if ((failures > 0)); then
  printf '\033[1;31mDesktop-tools verification failed:\033[0m %d failure(s), %d warning(s)\n' \
    "$failures" "$warnings"
  exit 1
fi

printf '\033[1;32mDesktop-tools verification passed.\033[0m %d warning(s)\n' "$warnings"
