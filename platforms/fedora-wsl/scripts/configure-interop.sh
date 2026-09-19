#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../lib/wsl.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/wsl.sh"

dry_run="false"
wsl_conf_file="${WSL_CONF_FILE:-/etc/wsl.conf}"

usage() {
  cat <<'EOF'
Usage: ./platforms/fedora-wsl/scripts/configure-interop.sh [options]

Ensures /etc/wsl.conf has the [interop] policy this WSL profile relies on:

  [interop]
  enabled=true
  appendWindowsPath=false

"enabled=true" keeps explicit Windows executable interop available (Windows
Explorer, the Windows clipboard, Windows OpenSSH, a Windows-hosted 1Password
SSH agent, and similar) for the small set of full-path helpers this profile
already uses (wsl-open, wsl-copy, wsl-paste). "appendWindowsPath=false" is
what actually keeps Windows directories out of the Linux $PATH -- WSL
appends them by default, which is what this repository's PATH sanitization
is otherwise working around after the fact on every login shell.

Every other section and key already in /etc/wsl.conf, including an existing
[boot] systemd=true, is preserved untouched: only the two [interop] keys
above are added or corrected. Safe to rerun; a rerun with the policy already
in place makes no changes and does not invoke sudo.

Options:
  --dry-run   Show the resulting /etc/wsl.conf without changing anything
  -h, --help  Show this help

A WSL restart is required before a changed /etc/wsl.conf takes effect: run
'wsl --shutdown' from Windows PowerShell (this affects every WSL
distribution, not just this one), then reopen this distribution.
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

require_fedora_wsl

# The existing file is the starting document, so failing to read it must never
# be mistaken for "there is no file yet". /etc/wsl.conf belongs to root and
# nothing guarantees it is readable by the user running this script: a
# non-default mode can withhold read from everyone else. An unreadable file
# read as empty would hand render_ini_section_keys an empty document, and the
# sudo-backed write below -- which *can* write it -- would then replace the
# whole file with just [interop]. That silently drops an existing
# [boot] systemd=true, which platforms/fedora-wsl/lib/containers.sh refuses to
# install containers without, and an existing [user] default=, which decides
# who the distribution logs in as. Neither is recoverable from this repository.
#
# So the read is attempted as this user first and then retried through the same
# privilege that performs the write. Keying the retry off the read actually
# failing, rather than off `[[ -r ]]`, covers every reason a read can fail and
# leaves no window between testing and reading.
current_content=""
if [[ -e "$wsl_conf_file" || -L "$wsl_conf_file" ]]; then
  if ! current_content="$(cat -- "$wsl_conf_file" 2>/dev/null)"; then
    current_content="$(sudo cat -- "$wsl_conf_file")" ||
      die "Cannot read $wsl_conf_file, with or without sudo. Refusing to continue: rewriting it from an empty document would replace every section it already has."
  fi
fi

new_content="$(render_ini_section_keys "$current_content" "interop" \
  "enabled=true" "appendWindowsPath=false")"

if [[ "$dry_run" == "true" ]]; then
  cat <<EOF

Fedora WSL interop policy plan
-------------------------------

Target file: $wsl_conf_file
EOF

  if [[ "$current_content" == "$new_content" ]]; then
    printf 'Already has the intended [interop] policy; no changes needed.\n'
  else
    cat <<EOF
Will be updated so it contains:

  [interop]
  enabled=true
  appendWindowsPath=false

Every other existing section and key, including an existing
[boot] systemd=true if present, is preserved unchanged. Resulting file:

$new_content

A restart is required before this takes effect: run 'wsl --shutdown' from
Windows PowerShell, then reopen this distribution.
EOF
  fi

  printf '\nNo changes were made.\n\n'
  exit 0
fi

if [[ "$current_content" == "$new_content" ]]; then
  info "$wsl_conf_file already has the intended [interop] policy"
  exit 0
fi

info "Updating $wsl_conf_file: [interop] enabled=true, appendWindowsPath=false"

# Keep whatever mode the file already has. 0644 is the right mode for a file
# this creates, but forcing it on an existing file would publish one an
# administrator deliberately restricted -- the same edit-in-place contract the
# rest of this script keeps for the file's other sections.
file_mode="0644"
if [[ -e "$wsl_conf_file" ]]; then
  existing_mode="$(stat -c '%a' -- "$wsl_conf_file" 2>/dev/null || true)"
  if [[ "$existing_mode" =~ ^[0-7]+$ ]]; then
    printf -v file_mode '%04o' "$((8#$existing_mode))"
  fi
fi

temp_file="$(mktemp)"
trap 'rm -f -- "$temp_file"' EXIT
printf '%s\n' "$new_content" >"$temp_file"
sudo install -m "$file_mode" "$temp_file" "$wsl_conf_file"

success "$wsl_conf_file now sets [interop] enabled=true / appendWindowsPath=false"
warn "Restart WSL for this to take effect: run 'wsl --shutdown' from Windows PowerShell (this affects every WSL distribution, not just this one), then reopen this distribution."
