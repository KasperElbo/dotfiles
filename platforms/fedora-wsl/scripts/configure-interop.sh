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

current_content=""
if [[ -r "$wsl_conf_file" ]]; then
  current_content="$(cat "$wsl_conf_file")"
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

temp_file="$(mktemp)"
trap 'rm -f -- "$temp_file"' EXIT
printf '%s\n' "$new_content" >"$temp_file"
sudo install -m 0644 "$temp_file" "$wsl_conf_file"

success "$wsl_conf_file now sets [interop] enabled=true / appendWindowsPath=false"
warn "Restart WSL for this to take effect: run 'wsl --shutdown' from Windows PowerShell (this affects every WSL distribution, not just this one), then reopen this distribution."
