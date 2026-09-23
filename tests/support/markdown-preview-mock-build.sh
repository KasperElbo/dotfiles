#!/usr/bin/env bash
set -euo pipefail

# Leave behind what markdown-preview.nvim's build leaves behind: a server in
# app/bin, under the name common/lib/markdown-preview.sh looks up for this
# machine, reporting the version the plugin's package.json names. The server is
# a stub; the installer and the verifier ask it only for its version.
#
# Usage: markdown-preview-mock-build.sh <plugin_dir>
#
# The package.json is written when the checkout has none, at the version the
# plugin reports at the commit lazy-lock.json pins.

# shellcheck source=../../common/lib/markdown-preview.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib/markdown-preview.sh"

plugin_dir="${1:?the markdown-preview.nvim plugin directory is required}"

[[ -f "$plugin_dir/package.json" ]] ||
  printf '{ "name": "markdown-preview", "version": "0.0.10" }\n' >"$plugin_dir/package.json"
version="$(jq -r '.version' "$plugin_dir/package.json")"

# Where upstream publishes no server, a real build leaves app/bin empty too.
server_name="$(markdown_preview_server_name)" || exit 0
mkdir -p "$plugin_dir/app/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$version" >"$plugin_dir/app/bin/$server_name"
chmod +x "$plugin_dir/app/bin/$server_name"
