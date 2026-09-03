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
shellcheck -x -P SCRIPTDIR -s bash "${shell_files[@]}"

printf 'Shell validation passed.\n'
