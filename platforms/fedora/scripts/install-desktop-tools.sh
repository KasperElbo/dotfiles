#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/fedora.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fedora.sh"

dry_run="false"

# Fedora's KDE baseline already ships these. Only install them if something
# removed them; never treat an existing install as a duplicate to replace.
baseline_packages=(
  ark
  gwenview
  okular
)

# The profile's deliberate additions: one image editor, one PDF page tool,
# a scanning front end, and the xdg-utils commands used to set MIME defaults.
added_packages=(
  gimp
  pdfarranger
  skanpage
  xdg-utils
)

# mimetype:desktop-file pairs. Only ever claimed if unset or already ours;
# see set_default_mime_type below.
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

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora/scripts/install-desktop-tools.sh [options]

Install the optional day-to-day desktop application profile: a general-purpose
image editor, a PDF page-manipulation tool, a reliable media player, and a
scanning front end, alongside the Fedora KDE baseline's existing image viewer,
PDF viewer, and archive manager (reused, not duplicated).

Options:
  --dry-run   Show the desktop-tools plan without changing anything
  -h, --help  Show this help
EOF
}

while (($#)); do
  case "$1" in
  --dry-run)
    dry_run="true"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1"
    ;;
  esac
done

missing_baseline_packages() {
  local package

  for package in "${baseline_packages[@]}"; do
    if ! rpm -q "$package" >/dev/null 2>&1; then
      printf '%s\n' "$package"
    fi
  done
}

set_default_mime_type() {
  local mime="$1"
  local desktop_entry="$2"
  local application_dir
  local desktop_file_found="false"
  local current

  for application_dir in \
    "$XDG_DATA_HOME/applications" \
    /usr/local/share/applications \
    /usr/share/applications; do
    if [[ -f "$application_dir/$desktop_entry" ]]; then
      desktop_file_found="true"
      break
    fi
  done

  if [[ "$desktop_file_found" == "false" ]]; then
    warn "Desktop entry not found, leaving $mime association unchanged: $desktop_entry"
    return
  fi

  current="$(xdg-mime query default "$mime" 2>/dev/null || true)"

  if [[ -z "$current" || "$current" == "$desktop_entry" ]]; then
    xdg-mime default "$desktop_entry" "$mime"
  else
    info "Keeping existing user default for $mime: $current"
  fi
}

if [[ "$dry_run" == "true" ]]; then
  mapfile -t missing_baseline < <(missing_baseline_packages)

  cat <<EOF

Fedora desktop-tools installation plan
---------------------------------------

Images:    Gwenview (viewer, reused from the KDE baseline) + GIMP (editor)
PDF:       Okular (viewer/annotation, reused from the KDE baseline) + pdfarranger
           (merge, split, reorder, extract pages)
Archives:  Ark (reused from the KDE baseline), integrated with Dolphin
Media:     mpv, backed by RPM Fusion's full ffmpeg for reliable playback
Scanning:  Skanpage

Fedora KDE baseline packages reused if already installed: ${baseline_packages[*]}
EOF

  if ((${#missing_baseline[@]} > 0)); then
    printf 'Currently missing and would be installed: %s\n' "${missing_baseline[*]}"
  else
    printf 'All already installed; none would be reinstalled.\n'
  fi

  cat <<EOF

Steps:
  1. Install any missing Fedora KDE baseline apps (${baseline_packages[*]}).
  2. Install the profile's additions: ${added_packages[*]}.
  3. Enable RPM Fusion and install mpv, backed by its full ffmpeg.
  4. Set default applications for images, PDFs, archives and media, without
     overriding a default you already changed yourself.
  5. Record the profile in \$XDG_CONFIG_HOME/dotfiles/desktop-tools.conf.

No changes were made.

EOF
  exit 0
fi

require_fedora

mapfile -t missing_baseline < <(missing_baseline_packages)

if ((${#missing_baseline[@]} > 0)); then
  info "Installing missing Fedora KDE baseline apps: ${missing_baseline[*]}"
  sudo dnf install -y "${missing_baseline[@]}"
else
  info "Fedora KDE baseline apps already installed: ${baseline_packages[*]}"
fi

info "Installing desktop-tools profile packages"
sudo dnf install -y "${added_packages[@]}"

info "Enabling RPM Fusion for full multimedia codec support"
ensure_rpm_fusion_repositories

info "Installing mpv"
sudo dnf install -y mpv

info "Setting default applications for images, PDFs, archives and media"
for mapping in "${mime_defaults[@]}"; do
  set_default_mime_type "${mapping%%:*}" "${mapping#*:}"
done

state_file="$XDG_CONFIG_HOME/dotfiles/desktop-tools.conf"
ensure_dir "$(dirname "$state_file")"
{
  printf 'profile=desktop-tools\n'
  printf 'image_viewer=gwenview\n'
  printf 'image_editor=gimp\n'
  printf 'pdf_viewer=okular\n'
  printf 'pdf_tool=pdfarranger\n'
  printf 'archive_manager=ark\n'
  printf 'media_player=mpv\n'
  printf 'scanner=skanpage\n'
} | atomic_write_file "$state_file"

success "Desktop-tools profile installed"
