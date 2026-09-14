#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../../../common/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/common.sh"
# shellcheck source=../../../common/lib/profile-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../../common/lib/profile-state.sh"
# shellcheck source=../lib/macos.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/macos.sh"

require_apple_silicon_macos
require_native_homebrew
activate_homebrew_path

info "Installing the optional Podman machine profile"
"$(homebrew_path)" install podman podman-compose

machine_count="$(podman machine list --format json | jq 'length')"
if [[ "$machine_count" == 0 ]]; then
  podman machine init --now
elif ! podman machine list --format json | jq -e 'any(.Running == true)' >/dev/null; then
  podman machine start
else
  info "A Podman machine is already running"
fi

info "Checking rootless ARM64 container execution"
podman info >/dev/null
# shellcheck disable=SC2016 # Expansion belongs inside the container shell.
# network-source: smoke-image-alpine
podman run --rm docker.io/library/alpine:latest sh -c \
  'test "$(uname -m)" = aarch64 && printf "Podman ARM64 smoke test passed\n"'
podman-compose version >/dev/null

state_file="$XDG_CONFIG_HOME/dotfiles/macos-containers.conf"
profile_state_write "$state_file" podman-machine installed rootful=false

success "Optional Podman machine profile installed"
