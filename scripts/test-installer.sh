#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

printf '%s\n' \
  'scripts/test-installer.sh is retained as a compatibility entry point.' \
  'Running the complete bootstrap test harness via scripts/test.sh.'

exec "$repo_root/scripts/test.sh"
