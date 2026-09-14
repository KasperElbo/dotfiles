#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd -- "$repo_root" || exit 1

usage() {
  cat <<'EOF_USAGE'
Usage: ./scripts/test.sh [--fail-fast] [test-script ...]

Normal mode runs every fast mocked/unit/contract suite, continues after
independent failures, and prints a final passed/failed/skipped summary.

Options:
  --fail-fast  Stop after the first failed suite; remaining suites are skipped.
  -h, --help   Show this help.

When test-script arguments are supplied, only those suites run. Targeted mode
relies on each selected suite to report its own missing dependencies, so it does
not require the full Linux aggregate toolchain. Set DOTFILES_TEST_REQUIRED_COMMANDS
explicitly when a targeted run needs runner-level dependency preflight.

Dependency policy:
  The default aggregate preflights the normal Linux validation toolchain.
  Commands in DOTFILES_TEST_REQUIRED_COMMANDS are always runner requirements.
  Missing runner requirements are an error before any suite runs; they are never
  silently treated as test success.
EOF_USAGE
}

fail_fast=false
selected_tests=()
while (($#)); do
  case "$1" in
  --fail-fast)
    fail_fast=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    selected_tests+=("$@")
    break
    ;;
  -*)
    printf 'Unknown option: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
  *)
    selected_tests+=("$1")
    shift
    ;;
  esac
done

default_tests=(
  tests/test-verifier.sh
  tests/test-test-support.sh
  tests/test-test-runner.sh
  tests/test-capabilities.sh
  tests/test-fedora-dependency-closure.sh
  tests/test-supply-chain.sh
  tests/test-profile-state.sh
  tests/test-execution-plan.sh
  tests/test-cli-contract.sh
  tests/test-installer-preflight.sh
  tests/test-doctor.sh
  tests/test-install-lifecycle.sh
  tests/test-secure-boot.sh
  tests/test-power-profiles.sh
  tests/test-installer-options.sh
  tests/test-platform-boundary.sh
  tests/test-local-state.sh
  tests/test-theme.sh
  tests/test-kde-theme.sh
  tests/test-sway-config.sh
  tests/test-cheatsheet-bindings.sh
  tests/test-neovim-tool-ownership.sh
  tests/test-csharpier-ownership.sh
  tests/test-dotnet-debugger-contract.sh
  tests/test-dap-smoke.py
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
  tests/test-ai-transitions.sh
  tests/test-mise-context.sh
  tests/test-vm-host.sh
  tests/test-vm-guest.sh
  tests/test-hardening.sh
  tests/test-desktop-tools.sh
  tests/test-containers.sh
  tests/test-containers-wsl.sh
  tests/test-tailscale.sh
  tests/test-wsl-interop.sh
  tests/test-wsl-open.sh
  tests/test-fedora-wsl.sh
  tests/test-parrot-ctf.sh
  tests/test-parrot-isolation.sh
  tests/test-parrot-terminal.sh
  tests/test-parrot-verification.sh
  tests/test-windows-bootstrap.sh
  tests/test-macos-bootstrap.sh
  tests/test-macos.sh
  tests/test-macos-login-shell.sh
)

if ((${#selected_tests[@]} > 0)); then
  tests=("${selected_tests[@]}")
else
  tests=("${default_tests[@]}")
fi

required_commands=()
if [[ -n "${DOTFILES_TEST_REQUIRED_COMMANDS:-}" ]]; then
  read -r -a required_commands <<<"$DOTFILES_TEST_REQUIRED_COMMANDS"
elif ((${#selected_tests[@]} == 0)); then
  required_commands=(awk bash find git grep jq mktemp nvim python3 rg sed stow timeout zsh)
fi

missing_commands=()
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done

if ((${#missing_commands[@]} > 0)); then
  printf 'ERROR: missing required test dependencies: %s\n' "${missing_commands[*]}" >&2
  printf 'Policy: runner dependencies are required; no suites were run or credited as skipped.\n' >&2
  exit 2
fi

passed=()
failed=()
skipped=()

run_suite() {
  local test_script="$1"
  local test_path="$test_script"
  [[ "$test_path" == /* ]] || test_path="$repo_root/$test_path"

  if [[ ! -f "$test_path" ]]; then
    printf 'Missing test suite: %s\n' "$test_script" >&2
    return 127
  fi

  if [[ -x "$test_path" ]]; then
    "$test_path"
  else
    bash "$test_path"
  fi
}

for ((index = 0; index < ${#tests[@]}; index++)); do
  test_script="${tests[index]}"
  printf '\n==> %s\n' "$test_script"

  if run_suite "$test_script"; then
    passed+=("$test_script")
  else
    status=$?
    failed+=("$test_script (exit $status)")
    if [[ "$fail_fast" == true ]]; then
      for ((remaining = index + 1; remaining < ${#tests[@]}; remaining++)); do
        skipped+=("${tests[remaining]} (fail-fast)")
      done
      break
    fi
  fi
done

printf '\nTest summary — mocked/unit/contract evidence\n'
printf '  passed:  %d\n' "${#passed[@]}"
printf '  failed:  %d\n' "${#failed[@]}"
printf '  skipped: %d\n' "${#skipped[@]}"

if ((${#failed[@]} > 0)); then
  printf '\nFailed suites:\n' >&2
  printf '  - %s\n' "${failed[@]}" >&2
fi
if ((${#skipped[@]} > 0)); then
  printf '\nSkipped suites:\n'
  printf '  - %s\n' "${skipped[@]}"
fi

if ((${#failed[@]} > 0)); then
  exit 1
fi

printf '\nAll required fast suites passed.\n'
