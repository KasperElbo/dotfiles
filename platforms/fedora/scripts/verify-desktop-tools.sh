#!/usr/bin/env bash
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/verify.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/verify.sh"

verify_reset

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

finish_verification "Desktop-tools verification"
