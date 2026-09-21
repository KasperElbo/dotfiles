#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mise_command="$(resolve_mise_command || true)"
[[ -n "$mise_command" ]] || die "Required command not found: mise"

config="$XDG_CONFIG_HOME/mise/config.toml"

[[ -f "$config" ]] || die "mise config not found: $config"

info "Installing tools declared in $config"
if [[ "${DOTFILES_VERBOSE:-false}" == "true" ]]; then
  mise_config_summary | while IFS= read -r line; do info "  mise $line"; done
fi

# Install time is when the deterministic context is built; run_mise only reads
# it (see lib/common.sh).
mise_prepare_context >/dev/null

run_mise "$mise_command" --yes install

establish_user_tool_environment

success "mise tools installed"
