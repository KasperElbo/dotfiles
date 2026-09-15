#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

mapfile -d '' shell_files < <(git ls-files -z -- '*.sh')

if ((${#shell_files[@]} == 0)); then
  printf 'No tracked shell files found.\n' >&2
  exit 1
fi

printf 'Checking Bash syntax in %d tracked files...\n' "${#shell_files[@]}"

for file in "${shell_files[@]}"; do
  bash -n "$file"
done

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'ShellCheck is required but was not found in PATH.\n' >&2
  exit 1
fi

printf 'Running ShellCheck...\n'
# -S warning: fail only on warning-and-above findings, so info-level notes
# that ShellCheck adds or removes between versions do not fail CI on version
# drift alone (see docs/testing.md's "Contributor toolchain" section).
shellcheck -x -P SCRIPTDIR -s bash -S warning "${shell_files[@]}"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required but was not found in PATH.\n' >&2
  exit 1
fi

printf 'Checking generated Starship configurations...\n'
./scripts/update-starship-themes.sh --check

printf 'Checking repository hygiene...\n'
python3 ./scripts/validate-repository-hygiene.py
python3 ./scripts/validate-shell-file-roles.py

printf 'Checking generated and cross-referenced documentation...\n'
python3 ./scripts/render-capability-matrix.py --check
python3 ./scripts/render-installer-options.py --check
python3 ./scripts/render-verifier-reference.py --check
python3 ./scripts/render-action-reference.py --check
python3 ./scripts/validate-actions.py
python3 ./scripts/validate-docs.py

printf 'Validating network-source provenance...\n'
python3 ./scripts/validate-capabilities.py
python3 ./scripts/validate-fedora-dependency-closure.py
python3 ./scripts/validate-network-sources.py
python3 ./scripts/render-supply-chain.py --check

printf 'Shell validation passed.\n'
