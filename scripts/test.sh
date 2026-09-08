#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

tests=(
  tests/test-secure-boot.sh
  tests/test-power-profiles.sh
  tests/test-installer-options.sh
  tests/test-platform-boundary.sh
  tests/test-local-state.sh
  tests/test-theme.sh
  tests/test-kde-theme.sh
  tests/test-sway-config.sh
  tests/test-neovim-tool-ownership.sh
  tests/test-neovim-bootstrap.sh
  tests/test-markdown-workflow.sh
  tests/test-latex-profile.sh
  tests/test-ocaml-profile.sh
  tests/test-idempotency.sh
  tests/test-asus-preflight.sh
  tests/test-asus-verification.sh
  tests/test-mocked-installs.sh
  tests/test-sftp-baseline.sh
  tests/test-ai-profile.sh
  tests/test-vm-host.sh
  tests/test-vm-guest.sh
  tests/test-hardening.sh
  tests/test-desktop-tools.sh
  tests/test-containers.sh
  tests/test-containers-wsl.sh
  tests/test-tailscale.sh
  tests/test-wsl-interop.sh
  tests/test-fedora-wsl.sh
  tests/test-parrot-ctf.sh
  tests/test-windows-bootstrap.sh
  tests/test-macos.sh
)

for test_script in "${tests[@]}"; do
  printf '\n==> %s\n' "$test_script"
  "$repo_root/$test_script"
done

printf '\nAll bootstrap tests passed.\n'
