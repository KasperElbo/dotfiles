#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mise_command="$(command -v mise 2>/dev/null || true)"

if [[ -z "$mise_command" && -x "$HOME/.local/bin/mise" ]]; then
  mise_command="$HOME/.local/bin/mise"
fi

[[ -n "$mise_command" ]] || die "Required command not found: mise"

config="$XDG_CONFIG_HOME/mise/config.toml"

[[ -f "$config" ]] || die "mise config not found: $config"

info "Installing tools declared in $config"

"$mise_command" --yes install

success "mise tools installed"
