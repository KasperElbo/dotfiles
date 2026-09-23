#!/usr/bin/env bash

# Markdown preview server identity.
#
# markdown-preview.nvim serves its page from a prebuilt server binary that the
# plugin's build step downloads into app/bin. Without it the preview command
# starts nothing and opens no browser, and says nothing about why: with Node on
# PATH the plugin falls back to its unbuilt JavaScript entry point, which dies
# on a missing module into a log nobody reads. So a plugin checkout at the
# locked commit proves nothing about the preview; only the binary does.
#
# This library is the one place that decides what "ready" means, so the
# installer's repair and the verifier's verdict cannot drift apart. The rule is
# upstream's own (mkdp#util#pre_build_version): the binary for this platform
# exists and reports the version in the plugin's package.json.
#
# Written for Apple's Bash 3.2, like lib/verify.sh, because the macOS verifier
# may run under /bin/bash.

if [[ -z "${DOTFILES_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# shellcheck disable=SC2034
DOTFILES_MARKDOWN_PREVIEW_LOADED=true

# Set by markdown_preview_server_status and read by its callers.
# shellcheck disable=SC2034
MARKDOWN_PREVIEW_STATE=""
# shellcheck disable=SC2034
MARKDOWN_PREVIEW_DETAIL=""

# markdown_preview_server_name
#
# The binary name upstream's install.sh downloads for this machine, spelled the
# way mkdp#util#get_platform() looks it up. Fails where upstream publishes none.
markdown_preview_server_name() {
  case "$(uname -s) $(uname -m)" in
  "Linux x86_64" | "Linux i686") printf 'markdown-preview-linux\n' ;;
  "Darwin arm64") printf 'markdown-preview-macos-arm64\n' ;;
  "Darwin x86_64") printf 'markdown-preview-macos\n' ;;
  *) return 1 ;;
  esac
}

# markdown_preview_server_status <plugin_dir>
#
# Sets MARKDOWN_PREVIEW_STATE to one of:
#   ready        the server for this machine reports the plugin's version
#   absent       no server binary: the build never ran, or never finished
#   stale        a server is there but answers with another version, or none
#   unsupported  upstream publishes no server for this machine
#   unreadable   the plugin's package.json names no version
# and MARKDOWN_PREVIEW_DETAIL to what the caller should print. Returns 0 only
# for ready.
# The two results are read by the callers that source this file.
# shellcheck disable=SC2034
markdown_preview_server_status() {
  local plugin_dir="$1"
  local name server expected reported

  MARKDOWN_PREVIEW_STATE=""
  MARKDOWN_PREVIEW_DETAIL=""

  if ! name="$(markdown_preview_server_name)"; then
    MARKDOWN_PREVIEW_STATE="unsupported"
    MARKDOWN_PREVIEW_DETAIL="no prebuilt Markdown preview server exists for $(uname -sm)"
    return 1
  fi

  expected="$(jq -r '.version // empty' "$plugin_dir/package.json" 2>/dev/null)" || expected=""
  if [[ -z "$expected" ]]; then
    MARKDOWN_PREVIEW_STATE="unreadable"
    MARKDOWN_PREVIEW_DETAIL="cannot read the plugin version from $plugin_dir/package.json"
    return 1
  fi

  server="$plugin_dir/app/bin/$name"
  if [[ ! -f "$server" || ! -x "$server" ]]; then
    MARKDOWN_PREVIEW_STATE="absent"
    MARKDOWN_PREVIEW_DETAIL="$server is missing"
    return 1
  fi

  # Captured whole and cut here rather than piped to head, so an early reader
  # exit cannot turn into a SIGPIPE failure of the probe itself.
  reported="$("$server" --version 2>/dev/null)" || reported=""
  reported="${reported%%$'\n'*}"
  if [[ "$reported" != "$expected" ]]; then
    MARKDOWN_PREVIEW_STATE="stale"
    MARKDOWN_PREVIEW_DETAIL="$server reports '${reported:-nothing}', expected $expected"
    return 1
  fi

  MARKDOWN_PREVIEW_STATE="ready"
  MARKDOWN_PREVIEW_DETAIL="$server $expected"
  return 0
}
