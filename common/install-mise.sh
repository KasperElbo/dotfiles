#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_command mise

config="$XDG_CONFIG_HOME/mise/config.toml"

[[ -f "$config" ]] || die "mise config not found: $config"

info "Installing tools declared in $config"

mise --yes install

success "mise tools installed"
