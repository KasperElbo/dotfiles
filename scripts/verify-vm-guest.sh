#!/usr/bin/env bash
set -euo pipefail

# Deprecated Fedora compatibility wrapper. It forwards unchanged; see
# docs/architecture/repository-conventions.md for the removal policy.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../common/lib/deprecation.sh
source "$repo_root/common/lib/deprecation.sh"

deprecated_wrapper "scripts/verify-vm-guest.sh" \
  "platforms/fedora/scripts/verify.sh" \
  "platforms/fedora/scripts/verify-vm-guest.sh"

exec "$repo_root/platforms/fedora/scripts/verify-vm-guest.sh" "$@"
